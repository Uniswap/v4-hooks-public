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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Tstorish} from "tstorish/Tstorish.sol";
import {IElfomoFi} from "./interfaces/IElfomoFi.sol";
import {IElfomoSwapCallback} from "./interfaces/IElfomoSwapCallback.sol";

/// @title ElfomoFiAggregator
/// @notice Singleton Uniswap V4 hook that aggregates liquidity from the ElfomoFi PropAMM router
/// @dev One canonical V4 pool per token pair. Uses the callback variant of ElfomoFi's swap logic
///      (`swapWithCallback`) so no standing approval is parked on the router.
///
///      Trust model: ElfomoFi's `pricing` is immutable on the deployed router and `vault` is
///      immutable; both are honest-counterparty trust anchors at deploy time. The hook enforces
///      that the engine reports the EXACT amount the user specified for the side they specified;
///      slippage on the unspecified side is the integrator's responsibility (use V4's Universal
///      Router or another slippage-aware caller).
///
///      Quote nuance: `IElfomoFi.getAmountOut`/`getAmountIn` hard-code `partnerId = 0` on the
///      deployed router, while `swapWithCallback` uses our configured `partnerId`. While
///      `partnerId == 0` the public `quote()` matches execution exactly. If a non-zero partner
///      ID is set in the future, integrators consuming `quote()` may observe drift if ElfomoFi's
///      pricing oracle prices partners differently.
/// @custom:security-contact security@uniswap.org
contract ElfomoFiAggregator is BaseAggregatorHook, IElfomoSwapCallback, Ownable, Tstorish {
    using StateLibrary for IPoolManager;

    /// @notice The ElfomoFi PropAMM router (same address on Base and BSC)
    IElfomoFi public immutable elfomoFi;

    /// @notice The ElfomoFi vault address that holds the protocol's inventory
    /// @dev ElfomoFi's `vault` is immutable on the deployed router; we accept it as a constructor
    ///      argument because the deployed router does not expose a getter.
    address public immutable elfomoFiVault;

    /// @notice Partner identifier used for rebate tracking on every swap
    /// @dev Defaults to 0 ("not used") until Uniswap is assigned a partner ID
    uint256 public immutable partnerId;

    /// @notice Token pair info for each registered pool
    struct PoolTokens {
        address token0;
        address token1;
    }

    /// @notice Maps Uniswap V4 pool IDs to their token addresses
    mapping(PoolId => PoolTokens) public poolIdToTokens;

    /// @dev Canonical V4 pool per ordered token pair; enforces one canonical V4 pool per pair
    mapping(bytes32 => PoolId) private _canonicalPoolByPair;

    /// @dev Slot that holds 1 while a swap from this hook is being processed by ElfomoFi.
    ///      Backed by TSTORE on chains with EIP-1153 support, SSTORE elsewhere (via Tstorish).
    ///      Value: `uint256(keccak256("aggregator-hooks.elfomo-fi.inflight")) - 1`.
    uint256 private constant INFLIGHT_SLOT = 0xbf35faecc380af431437a321ef8ef6b194285d57e89943775f424ab582ab8714;
    /// @dev Slot that captures the amount of `fromToken` ElfomoFi reports in the callback.
    ///      Value: `uint256(keccak256("aggregator-hooks.elfomo-fi.callback-amount-in")) - 1`.
    uint256 private constant CALLBACK_AMOUNT_IN_SLOT = 0xba9cd5fa12de9303ee2a6860411fa6a29fe681192d5c194de5fb3ec2a4f5f0ac;
    /// @dev Slot that captures the amount of `toToken` ElfomoFi reports in the callback.
    ///      Value: `uint256(keccak256("aggregator-hooks.elfomo-fi.callback-amount-out")) - 1`.
    uint256 private constant CALLBACK_AMOUNT_OUT_SLOT = 0x0c3c2eaa0f36d92d1462d72fc6eb299bf0f62fd769692de3ac027ff56932f068;

    /// @notice Emitted when the owner deregisters a canonical pair, freeing it for a new pool
    /// @param poolId The pool id that was holding the canonical slot for the pair.
    /// @param token0 The pair's lower-address token.
    /// @param token1 The pair's higher-address token.
    event PairDeregistered(PoolId indexed poolId, address token0, address token1);

    /// @dev Thrown when `elfomoSwapCallback` is invoked by an address other than `elfomoFi`.
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
    /// @dev Thrown when ElfomoFi's pricing oracle reverts or returns zero for either direction.
    /// @param token0 The pair's lower-address token.
    /// @param token1 The pair's higher-address token.
    error PairNotSupported(address token0, address token1);
    /// @dev Thrown when a constructor argument is the zero address.
    error ZeroAddress();
    /// @dev Thrown when ElfomoFi reports out-of-spec callback parameter signs
    ///      (expected: `fromTokenDelta > 0`, `toTokenDelta < 0`).
    error InvalidCallbackAmounts(int256 fromTokenDelta, int256 toTokenDelta);
    /// @dev Thrown when ElfomoFi's reported amount on the specified side disagrees with what the
    ///      V4 swap asked for. Catches engine bugs without depending on integrator slippage.
    /// @param requested The absolute amount the V4 swap specified.
    /// @param reported The amount ElfomoFi reported for the specified side.
    error EngineSpecifiedAmountMismatch(uint256 requested, uint256 reported);
    /// @dev Thrown when ETH is sent directly to the hook (no legitimate ETH path exists).
    error NoEthAccepted();
    /// @dev Thrown when an attempted deregistration targets a pool id that isn't currently the
    ///      canonical pool for the given pair.
    error NotCanonicalPool(PoolId requested, PoolId canonical);

    /// @param _manager The Uniswap V4 PoolManager contract.
    /// @param _elfomoFi The ElfomoFi PropAMM router (same address on Base and BSC at deploy time).
    /// @param _elfomoFiVault The ElfomoFi vault address that holds protocol inventory.
    /// @param _partnerId Partner identifier used on every `swapWithCallback`. Use `0` until Uniswap
    ///        is assigned an official partner ID for ElfomoFi rebates.
    /// @param _owner The address that may deregister squatted canonical pairs.
    constructor(
        IPoolManager _manager,
        IElfomoFi _elfomoFi,
        address _elfomoFiVault,
        uint256 _partnerId,
        address _owner
    ) BaseAggregatorHook(_manager, "ElfomoFiAggregator v1.0") Ownable(_owner) {
        if (address(_manager) == address(0)) revert ZeroAddress();
        if (address(_elfomoFi) == address(0)) revert ZeroAddress();
        if (_elfomoFiVault == address(0)) revert ZeroAddress();
        // Ownable's constructor already rejects `address(0)` for `_owner`.
        elfomoFi = _elfomoFi;
        elfomoFiVault = _elfomoFiVault;
        partnerId = _partnerId;
    }

    /// @inheritdoc IElfomoSwapCallback
    /// @dev Called by ElfomoFi during `swapWithCallback`. Must transfer `uint256(fromTokenDelta)`
    ///      of the input token to the ElfomoFi contract before returning.
    function elfomoSwapCallback(int256 fromTokenDelta, int256 toTokenDelta, bytes calldata data) external override {
        if (msg.sender != address(elfomoFi)) revert UnauthorizedCallback();
        if (!_isInflight()) revert ProhibitedEntry();
        if (fromTokenDelta <= 0 || toTokenDelta >= 0) revert InvalidCallbackAmounts(fromTokenDelta, toTokenDelta);

        uint256 amountIn = uint256(fromTokenDelta);
        uint256 amountOut = uint256(-toTokenDelta);
        _writeCallbackAmounts(amountIn, amountOut);

        Currency takeCurrency = abi.decode(data, (Currency));
        poolManager.take(takeCurrency, address(elfomoFi), amountIn);
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

        address fromToken = zeroToOne ? tokens.token0 : tokens.token1;
        address toToken = zeroToOne ? tokens.token1 : tokens.token0;

        if (amountSpecified < 0) {
            // Exact-In: pricing returns the expected output
            amountUnspecified = elfomoFi.getAmountOut(fromToken, toToken, uint256(-amountSpecified));
        } else {
            // Exact-Out: pricing returns the required input
            amountUnspecified = elfomoFi.getAmountIn(fromToken, toToken, uint256(amountSpecified));
        }
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev Reads `balanceOf(elfomoFiVault)` for both tokens (ElfomoFi's vault holds the protocol's
    ///      live inventory). Reading the router itself would return ~zero in steady state.
    function pseudoTotalValueLocked(PoolId poolId) external view override returns (uint256 amount0, uint256 amount1) {
        PoolTokens storage tokens = poolIdToTokens[poolId];
        if (tokens.token0 == address(0) && tokens.token1 == address(0)) revert PoolDoesNotExist();
        amount0 = IERC20(tokens.token0).balanceOf(elfomoFiVault);
        amount1 = IERC20(tokens.token1).balanceOf(elfomoFiVault);
    }

    /// @notice Free the canonical pair slot for a pool that was squatted with junk parameters.
    /// @dev `_beforeInitialize` is permissionless (so anyone can mine + initialize a hook address),
    ///      which means a griefer can front-run the team's intended `initialize()` with poison
    ///      fee/tickSpacing/sqrtPriceX96 and permanently occupy the canonical slot. This function
    ///      gives the owner an evict path. It only clears the local mapping — the V4 pool itself
    ///      is unaffected and the squatter retains whatever they already initialized.
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
    /// @dev Rejects native ETH pools, probes the pricing oracle in BOTH directions with one whole
    ///      token of `token0` and `token1` respectively to confirm bidirectional support, enforces
    ///      one canonical V4 pool per token pair, and registers token addresses for the pool id.
    ///      A pair that only quotes in one direction is rejected (would otherwise leave half the V4
    ///      pool reverting on every swap).
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);

        if (token0 == address(0) || token1 == address(0)) revert NativeCurrencyNotSupported();

        // Bidirectional, decimals-aware probe. "One whole token" is a far more robust probe than a
        // constant base-unit amount: it scales with each side's decimals so high-decimal/high-price
        // pairs (e.g. 18-decimal tokens trading at thousands of USDC) still produce a non-zero quote
        // after the oracle's fee/rounding.
        _probePair(token0, token1);
        _probePair(token1, token0);

        bytes32 pairKey = _canonicalPairKey(token0, token1);
        PoolId existing = _canonicalPoolByPair[pairKey];
        if (PoolId.unwrap(existing) != bytes32(0)) {
            revert PairAlreadyRegistered(existing, token0, token1);
        }
        _canonicalPoolByPair[pairKey] = key.toId();

        poolIdToTokens[key.toId()] = PoolTokens({token0: token0, token1: token1});

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
        _callElfomoFi(takeCurrency, settleCurrency, params.amountSpecified);
        (amountTake, amountSettle) = _readCallbackAmounts();

        // Engine must agree on the side the user signed off on. Slippage on the unspecified side
        // is the integrator's responsibility (Universal Router etc.). This check is free (no extra
        // external call) and catches engine bugs that would silently mis-size the specified side.
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
    function _callElfomoFi(Currency takeCurrency, Currency settleCurrency, int256 v4AmountSpecified) private {
        // V4 encodes `amountSpecified < 0` as exact-in; ElfomoFi encodes `specifiedAmount > 0` as exact-in.
        int256 elfomoSpecified = -v4AmountSpecified;
        // Loose router-level limit because slippage protection is the integrator's responsibility
        // (Universal Router etc.). The engine-side specified-amount check in `_conductSwap` is the
        // hook's defense-in-depth against engine bugs.
        uint256 limitAmount = v4AmountSpecified < 0 ? 0 : type(uint256).max;
        elfomoFi.swapWithCallback(
            Currency.unwrap(takeCurrency),
            Currency.unwrap(settleCurrency),
            elfomoSpecified,
            limitAmount,
            address(poolManager),
            partnerId,
            abi.encode(takeCurrency)
        );
    }

    /// @dev Probe ElfomoFi's pricing oracle for support of (fromToken -> toToken). Reverts unless
    ///      the oracle returns a non-zero quote for one whole `fromToken`.
    function _probePair(address fromToken, address toToken) private view {
        uint256 probe = 10 ** uint256(IERC20Metadata(fromToken).decimals());
        try elfomoFi.getAmountOut(fromToken, toToken, probe) returns (uint256 quote) {
            if (quote == 0) revert PairNotSupported(fromToken, toToken);
        } catch {
            revert PairNotSupported(fromToken, toToken);
        }
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
    /// @param value `true` while a swap from this hook is in flight on ElfomoFi.
    function _setInflight(bool value) private {
        if (value) {
            _setTstorish(INFLIGHT_SLOT, 1);
        } else {
            _clearTstorish(INFLIGHT_SLOT);
        }
    }

    /// @dev Reads the inflight sentinel via Tstorish.
    /// @return value `true` if a swap from this hook is currently in flight on ElfomoFi.
    function _isInflight() private view returns (bool value) {
        value = _getTstorish(INFLIGHT_SLOT) != 0;
    }

    /// @dev Captures the amounts ElfomoFi reported in the most recent callback.
    /// @param amountIn Amount of `takeCurrency` (input) ElfomoFi consumed, in token base units.
    /// @param amountOut Amount of `settleCurrency` (output) ElfomoFi delivered to PoolManager, in token base units.
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
