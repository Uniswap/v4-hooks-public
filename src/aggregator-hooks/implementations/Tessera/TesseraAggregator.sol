// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Tstorish} from "tstorish/Tstorish.sol";
import {ITesseraSwap} from "./interfaces/ITesseraSwap.sol";
import {ITesseraSwapCallback} from "./interfaces/ITesseraSwapCallback.sol";
import {ITesseraManager} from "./interfaces/ITesseraManager.sol";
import {ITesseraPool} from "./interfaces/ITesseraPool.sol";

/// @title TesseraAggregator
/// @notice Singleton Uniswap V4 hook that aggregates liquidity from the Tessera V EVM PropAMM
/// @dev One canonical V4 pool per token pair. Uses the callback variant of Tessera's swap logic
///      (`tesseraSwapWithCallback`) so no standing approval is parked on the router.
///
///      Counterparty trust model (IMPORTANT):
///        - `tesseraEngine` and `tesseraTreasury` are storage variables on the deployed `TesseraSwap`
///          contract, mutable by a single `tesseraOwner` EOA with no timelock. The engine is the
///          sole authority on the `(amountIn, amountOut)` pair reported to this hook's callback.
///        - The hook defends against known possible edge cases, but not against the operator acting
///          maliciously. Tessera reports the amount the user specified for the side they specified.
///          Integrators must therefore enforce slippage on the unspecified side (Universal Router
///          and similar swap-routers do this). Direct `PoolManager.swap` callers without slippage
///          protection are exposed to whatever Tessera reports for the unspecified side.
///        - `tradingEnabled()` is checked only at pool registration. If Tessera operators disable
///          a registered pool, swaps will revert opaquely inside Tessera's code; the owner of this
///          hook can call `deregisterPair` to free the canonical slot for a fresh registration. The
///          owner can also evict a squatter that front-ran the team's intended `initialize()` with
///          poison `fee`/`tickSpacing`/`sqrtPriceX96` parameters.
/// @custom:security-contact security@uniswap.org
contract TesseraAggregator is BaseAggregatorHook, ITesseraSwapCallback, Ownable, Tstorish {
    using StateLibrary for IPoolManager;

    /// @notice The TesseraSwap router (same address on Base and BSC)
    ITesseraSwap public immutable tesseraSwap;
    /// @notice The Tessera pool registry (same address on Base and BSC)
    ITesseraManager public immutable tesseraManager;
    /// @notice The Tessera treasury address that holds the protocol's inventory
    /// @dev `tesseraTreasury` is a private storage variable on the deployed `TesseraSwap`. We accept
    ///      it here as a constructor argument because the deployed router does not expose a getter.
    ///      Note that the treasury is owner-mutable on `TesseraSwap`; if it changes, this hook's
    ///      `pseudoTotalValueLocked` reading goes stale until the hook is redeployed.
    address public immutable tesseraTreasury;

    /// @notice Token pair info for each registered pool, plus the underlying Tessera pool address
    ///         used for `pseudoTotalValueLocked` lookups.
    struct PoolTokens {
        address token0;
        address token1;
        address tesseraPool;
    }

    /// @notice Maps Uniswap V4 pool IDs to their token addresses and the underlying Tessera pool
    mapping(PoolId => PoolTokens) public poolIdToTokens;

    /// @dev Canonical V4 pool per ordered token pair (Tempo pattern); enforces one canonical V4 pool per pair
    mapping(bytes32 => PoolId) private _canonicalPoolByPair;

    /// @dev Slot that holds 1 while a swap from this hook is being processed by TesseraSwap.
    ///      Backed by TSTORE on chains with EIP-1153 support, SSTORE elsewhere (via Tstorish).
    ///      Value: `uint256(keccak256("aggregator-hooks.tessera.inflight")) - 1`.
    uint256 private constant INFLIGHT_SLOT = 0x11a0603b55240a854fd60675cd448f7099007c1401b0c576c7adaf6e4455a553;
    /// @dev Slot that captures the input amount TesseraSwap reports in the callback.
    ///      Value: `uint256(keccak256("aggregator-hooks.tessera.callback-amount-in")) - 1`.
    uint256 private constant CALLBACK_AMOUNT_IN_SLOT =
        0xdb305eccc6a8a82989ca68cc0fc484c898db8ebe32aeda1251ea1898bada2364;
    /// @dev Slot that captures the output amount TesseraSwap reports in the callback.
    ///      Value: `uint256(keccak256("aggregator-hooks.tessera.callback-amount-out")) - 1`.
    uint256 private constant CALLBACK_AMOUNT_OUT_SLOT =
        0xf2c0893ae0a70fd8a5cc13e7f46d2b6cf9ff1f1fd3fcfd40c23a292ae5f5ed3e;

    /// @notice Emitted when the owner deregisters a canonical pair, freeing it for a new pool
    /// @param poolId The pool id that was holding the canonical slot for the pair.
    /// @param token0 The pair's lower-address token.
    /// @param token1 The pair's higher-address token.
    event PairDeregistered(PoolId indexed poolId, address token0, address token1);

    /// @dev Thrown when `tesseraSwapCallback` is invoked by an address other than `tesseraSwap`.
    error UnauthorizedCallback();
    /// @dev Thrown when the callback runs without the transient inflight flag set
    ///      (i.e. not invoked as part of an in-flight `_conductSwap`).
    error ProhibitedEntry();
    /// @dev Thrown when `_conductSwap` is re-entered while a prior swap is still in flight.
    error Reentrancy();
    /// @dev Thrown when `_beforeInitialize` is called with `address(0)` as either currency.
    error NativeCurrencyNotSupported();
    /// @dev Thrown when a token pair already has a canonical V4 pool registered with this hook.
    /// @param existingPoolId The pool id of the previously-registered V4 pool for the pair.
    /// @param token0 The pair's lower-address token.
    /// @param token1 The pair's higher-address token.
    error PairAlreadyRegistered(PoolId existingPoolId, address token0, address token1);
    /// @dev Thrown when the Tessera manager has no direct pool registered for the given pair
    ///      (multi-hop pairs that would route through `baseRoutingAsset` are intentionally rejected).
    /// @param token0 The pair's lower-address token.
    /// @param token1 The pair's higher-address token.
    error PairNotSupported(address token0, address token1);
    /// @dev Thrown when the underlying Tessera pool exists but currently has trading disabled.
    /// @param pool The address of the underlying Tessera pool with `tradingEnabled == false`.
    error PoolTradingDisabled(address pool);
    /// @dev Thrown when a constructor argument is the zero address.
    error ZeroAddress();
    /// @dev Thrown when TesseraSwap reports out-of-spec callback parameter signs
    ///      (expected: `amountInDelta > 0`, `amountOutDelta < 0`).
    error InvalidCallbackAmounts(int256 amountInDelta, int256 amountOutDelta);
    /// @dev Thrown when the Tessera engine's reported amount on the specified side disagrees with
    ///      what the V4 swap asked for. Catches engine bugs without depending on integrator slippage.
    /// @param requested The absolute amount the V4 swap specified.
    /// @param reported The amount the engine reported for the specified side.
    error EngineSpecifiedAmountMismatch(uint256 requested, uint256 reported);
    /// @dev Thrown when ETH is sent directly to the hook (no legitimate ETH path exists).
    error NoEthAccepted();
    /// @dev Thrown when an attempted deregistration targets a pool id that isn't currently the
    ///      canonical pool for the given pair.
    error NotCanonicalPool(PoolId requested, PoolId canonical);

    /// @param _manager The Uniswap V4 PoolManager contract.
    /// @param _tesseraSwap The TesseraSwap router (same address on Base and BSC at deploy time).
    /// @param _tesseraManager The Tessera pool registry (same address on Base and BSC at deploy time).
    /// @param _tesseraTreasury The Tessera treasury that holds inventory (used by `pseudoTotalValueLocked`).
    /// @param _owner The address that may deregister squatted canonical pairs.
    constructor(
        IPoolManager _manager,
        ITesseraSwap _tesseraSwap,
        ITesseraManager _tesseraManager,
        address _tesseraTreasury,
        address _owner
    ) BaseAggregatorHook(_manager, "TesseraAggregator v1.0") Ownable(_owner) {
        if (address(_manager) == address(0)) revert ZeroAddress();
        if (address(_tesseraSwap) == address(0)) revert ZeroAddress();
        if (address(_tesseraManager) == address(0)) revert ZeroAddress();
        if (_tesseraTreasury == address(0)) revert ZeroAddress();
        // Ownable's constructor already rejects `address(0)` for `_owner`.
        tesseraSwap = _tesseraSwap;
        tesseraManager = _tesseraManager;
        tesseraTreasury = _tesseraTreasury;
    }

    /// @inheritdoc ITesseraSwapCallback
    /// @dev Called by TesseraSwap during `tesseraSwapWithCallback`. Must transfer `uint256(amountInDelta)`
    ///      of the input token to the TesseraSwap contract before returning.
    function tesseraSwapCallback(int256 amountInDelta, int256 amountOutDelta, bytes calldata data) external override {
        if (msg.sender != address(tesseraSwap)) revert UnauthorizedCallback();
        if (!_isInflight()) revert ProhibitedEntry();
        if (amountInDelta <= 0 || amountOutDelta >= 0) revert InvalidCallbackAmounts(amountInDelta, amountOutDelta);

        uint256 amountIn = uint256(amountInDelta);
        uint256 amountOut = uint256(-amountOutDelta);
        _writeCallbackAmounts(amountIn, amountOut);

        Currency takeCurrency = abi.decode(data, (Currency));
        poolManager.take(takeCurrency, address(tesseraSwap), amountIn);
    }

    /// @inheritdoc BaseAggregatorHook
    function _rawQuote(bool zeroToOne, int256 amountSpecified, PoolId poolId)
        internal
        view
        override
        returns (uint256 amountUnspecified)
    {
        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0) && tokens.token1 == address(0)) revert PoolDoesNotExist();

        address tokenIn = zeroToOne ? tokens.token0 : tokens.token1;
        address tokenOut = zeroToOne ? tokens.token1 : tokens.token0;

        // V4: amountSpecified < 0 = exact-in; Tessera: amountSpecified > 0 = exact-in
        (uint256 amountIn, uint256 amountOut) = tesseraSwap.tesseraSwapViewAmounts(tokenIn, tokenOut, -amountSpecified);
        amountUnspecified = amountSpecified < 0 ? amountOut : amountIn;
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Reads `balanceOf(tesseraTreasury)` for both tokens (Tessera's treasury holds the
    ///      protocol's live inventory). The per-pool `tesseraPool` contract holds no inventory.
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0) && tokens.token1 == address(0)) revert PoolDoesNotExist();
        amount0 = IERC20(tokens.token0).balanceOf(tesseraTreasury);
        amount1 = IERC20(tokens.token1).balanceOf(tesseraTreasury);
    }

    /// @notice Free the canonical pair slot for a pool that was squatted with junk parameters or
    ///         for a pair whose underlying Tessera pool has been retired by the operator.
    /// @dev `_beforeInitialize` is permissionless, so anyone can front-run the team's intended
    ///      registration with poison fee/tickSpacing/sqrtPriceX96 and squat the canonical slot.
    ///      This function gives the owner an evict path. It only clears the local mapping — the V4
    ///      pool itself is unaffected and any squatter retains whatever they already initialized.
    /// @param poolId The pool id currently holding the canonical slot for the pair.
    /// @param token0 The pair's lower-address token (pre-sorted is fine; the function re-sorts).
    /// @param token1 The pair's higher-address token (pre-sorted is fine; the function re-sorts).
    function deregisterPair(PoolId poolId, address token0, address token1) external onlyOwner {
        bytes32 pairKey = _canonicalPairKey(token0, token1);
        PoolId canonical = _canonicalPoolByPair[pairKey];
        if (PoolId.unwrap(canonical) != PoolId.unwrap(poolId)) revert NotCanonicalPool(poolId, canonical);
        _canonicalPoolByPair[pairKey] = PoolId.wrap(bytes32(0));
        delete poolIdToTokens[poolId];
        emit PairDeregistered(poolId, token0, token1);
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Rejects native ETH pools, looks up the underlying Tessera pool through the manager
    ///      (rejecting multi-hop / unregistered pairs), enforces that the pool is currently trading,
    ///      enforces one canonical V4 pool per pair, and registers token addresses for the pool id.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (token0 == address(0) || token1 == address(0)) revert NativeCurrencyNotSupported();

        (bool exists, address pool) = tesseraManager.getTesseraPool(token0, token1);
        if (!exists) revert PairNotSupported(token0, token1);

        if (!ITesseraPool(pool).tradingEnabled()) revert PoolTradingDisabled(pool);

        bytes32 pairKey = _canonicalPairKey(token0, token1);
        PoolId existing = _canonicalPoolByPair[pairKey];
        if (PoolId.unwrap(existing) != bytes32(0)) {
            revert PairAlreadyRegistered(existing, token0, token1);
        }
        _canonicalPoolByPair[pairKey] = key.toId();

        poolIdToTokens[key.toId()] = PoolTokens({token0: token0, token1: token1, tesseraPool: pool});

        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseAggregatorHook
    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        if (_isInflight()) revert Reentrancy();

        poolManager.sync(settleCurrency);

        _setInflight(true);
        _callTesseraSwap(takeCurrency, settleCurrency, params.amountSpecified);
        (amountTake, amountSettle) = _readCallbackAmounts();

        // Engine must agree on the side the user signed off on. Slippage on the unspecified side
        // is the integrator's responsibility (Universal Router etc.). This check is free (no extra
        // external call — Tessera's view path is too expensive to consult here) and catches engine
        // bugs or operator-installed engines that mis-size the specified side.
        _assertSpecifiedAmountMatch(params.amountSpecified, amountTake, amountSettle);

        poolManager.settle();
        // Clear inflight + the captured amounts so chains running Tstorish's SSTORE fallback don't
        // leave non-zero values in storage between swaps (and don't carry stale captured amounts).
        _setInflight(false);
        _clearTstorish(CALLBACK_AMOUNT_IN_SLOT);
        _clearTstorish(CALLBACK_AMOUNT_OUT_SLOT);
        hasSettled = true;
    }

    /// @dev Override `BaseAggregatorHook.receive()` to reject ETH outright. This hook never holds
    ///      native ETH (`_beforeInitialize` rejects native-currency pools), so any ETH that arrives
    ///      would be permanently stranded.
    receive() external payable override {
        revert NoEthAccepted();
    }

    /// @dev Extracted to avoid stack-too-deep in `_conductSwap`
    function _callTesseraSwap(Currency takeCurrency, Currency settleCurrency, int256 v4AmountSpecified) private {
        int256 tesseraSpecified = -v4AmountSpecified;
        // Loose router-level limit because slippage protection is the integrator's responsibility
        // (Universal Router etc.). The engine-side specified-amount check in `_conductSwap` is the
        // hook's defense-in-depth against engine bugs.
        uint256 amountCheck = v4AmountSpecified < 0 ? 0 : type(uint256).max;
        tesseraSwap.tesseraSwapWithCallback(
            Currency.unwrap(takeCurrency),
            Currency.unwrap(settleCurrency),
            tesseraSpecified,
            amountCheck,
            address(poolManager),
            abi.encode(takeCurrency),
            bytes("")
        );
    }

    /// @dev Asserts that the engine's reported amount on the specified side matches what the
    ///      V4 swap requested. For exact-in (`v4AmountSpecified < 0`), the engine must consume
    ///      exactly `-v4AmountSpecified` of input. For exact-out (`> 0`), the engine must deliver
    ///      exactly `v4AmountSpecified` of output. The unspecified-side amount is unbounded here;
    ///      use V4's outer router for slippage protection.
    function _assertSpecifiedAmountMatch(int256 v4AmountSpecified, uint256 amountTake, uint256 amountSettle)
        private
        pure
    {
        if (v4AmountSpecified < 0) {
            uint256 requested = uint256(-v4AmountSpecified);
            if (amountTake != requested) revert EngineSpecifiedAmountMismatch(requested, amountTake);
        } else {
            uint256 requested = uint256(v4AmountSpecified);
            if (amountSettle != requested) revert EngineSpecifiedAmountMismatch(requested, amountSettle);
        }
    }

    /// @dev Returns the canonical storage key for a token pair, order-independent.
    /// @param token0 One side of the pair (any ordering).
    /// @param token1 The other side of the pair.
    /// @return The canonical pair key, derived from the two addresses sorted ascending.
    function _canonicalPairKey(address token0, address token1) private pure returns (bytes32) {
        (address t0, address t1) = token0 < token1 ? (token0, token1) : (token1, token0);
        return keccak256(abi.encode(t0, t1));
    }

    /// @dev Writes the inflight sentinel via Tstorish (TSTORE if available, SSTORE fallback).
    /// @param value `true` while a swap from this hook is in flight on TesseraSwap.
    function _setInflight(bool value) private {
        if (value) {
            _setTstorish(INFLIGHT_SLOT, 1);
        } else {
            _clearTstorish(INFLIGHT_SLOT);
        }
    }

    /// @dev Reads the inflight sentinel via Tstorish.
    /// @return value `true` if a swap from this hook is currently in flight on TesseraSwap.
    function _isInflight() private view returns (bool value) {
        value = _getTstorish(INFLIGHT_SLOT) != 0;
    }

    /// @dev Captures the amounts TesseraSwap reported in the most recent callback.
    /// @param amountIn Amount of `takeCurrency` (input) TesseraSwap consumed, in token base units.
    /// @param amountOut Amount of `settleCurrency` (output) TesseraSwap delivered to PoolManager, in token base units.
    function _writeCallbackAmounts(uint256 amountIn, uint256 amountOut) private {
        _setTstorish(CALLBACK_AMOUNT_IN_SLOT, amountIn);
        _setTstorish(CALLBACK_AMOUNT_OUT_SLOT, amountOut);
    }

    /// @dev Reads back the amounts captured by the last callback.
    /// @return amountIn Amount of `takeCurrency` (input) consumed, in token base units.
    /// @return amountOut Amount of `settleCurrency` (output) delivered to PoolManager, in token base units.
    function _readCallbackAmounts() private view returns (uint256 amountIn, uint256 amountOut) {
        amountIn = _getTstorish(CALLBACK_AMOUNT_IN_SLOT);
        amountOut = _getTstorish(CALLBACK_AMOUNT_OUT_SLOT);
    }
}
