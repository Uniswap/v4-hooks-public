// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import {BaseAggregatorHook} from "../../BaseAggregatorHook.sol";
import {BaseHookDataAggregator} from "../../BaseHookDataAggregator.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {IReactor} from "@uniswapx/interfaces/IReactor.sol";
import {IReactorCallback} from "@uniswapx/interfaces/IReactorCallback.sol";
import {ResolvedOrder, SignedOrder} from "@uniswapx/base/ReactorStructs.sol";
import {OrderQuoter} from "@uniswapx/lens/OrderQuoter.sol";

/// @title UniswapXAggregator
/// @notice Uniswap V4 hook whose "liquidity source" is a single UniswapX order (e.g. a Dutch order)
///         supplied as swap `hookData`. The hook acts as the UniswapX filler: it calls the Reactor's
///         `executeWithCallback`, the Reactor pulls the order swapper's input (via Permit2) to this hook
///         and invokes `reactorCallback`, during which the hook sources the order's required output from
///         the V4 PoolManager (i.e. from the V4 swapper). The V4 swapper therefore provides the counter-side
///         liquidity that fills the UniswapX order and, in return, receives the order's input token.
/// @dev    Original Dutch orders are all-or-nothing: the V4 swap amount must exactly match the resolved order
///         amounts, otherwise the swap reverts. Each swap consumes one order passed fresh via `hookData`, so a
///         single deployed pool is reusable across many orders for the same token pair.
/// @dev    Stateless across pools: this hook holds no per-pool configuration (the order fully determines the
///         token pair and amounts at swap time), so one deployed hook instance can be the `hooks` address for
///         any number of V4 pools — no per-pool factory or deployment is needed. Simply mine one hook address
///         (see `AggregatorHookMiner`/`HookMiner`), deploy it once, then call `PoolManager.initialize` directly
///         for each pool that should use it.
/// @dev    Routing-style quoting (no hookData) is unsupported: `quote`/`_rawQuote`/`pseudoTotalValueLocked` revert
///         because the order is only known at swap time. Use `quoteWithHookData`, which resolves the supplied order
///         via UniswapX's OrderQuoter (note: not a view — see `_rawQuoteWithHookData`).
/// @dev    Protocol fees must remain 0 for pools using this hook. A non-zero protocol fee would skim the
///         unspecified currency, but an exact order fill leaves no surplus to cover it, causing settlement to fail.
contract UniswapXAggregator is BaseHookDataAggregator, IReactorCallback {
    using StateLibrary for IPoolManager;
    using SafeERC20 for IERC20;

    /// @notice The UniswapX reactor this hook fills orders against
    IReactor public immutable reactor;
    /// @notice The canonical wrapped-native token, used to bridge V4 native ETH and order WETH
    address public immutable weth;
    /// @notice Lens used to resolve an order (Dutch decay applied) into its current input/output amounts
    OrderQuoter public immutable orderQuoter;

    /// @notice Tracks which V4 pools have been registered with this hook
    mapping(PoolId => bool) public registered;

    // Unique, fixed transient-storage slots (EIP-1153). Transient storage is per-contract; these are chosen
    // distinct from any low slots used elsewhere in the inheritance chain.
    // The inflight (reentrancy / authorized-callback) flag.
    bytes32 private constant INFLIGHT_SLOT = 0x9d6f6b3c2a1e4f8b0c5d7e9a3b1f2c4d6e8a0b2c4d6e8f0a1b3c5d7e9f1a3b5c;
    // Scratch slots written by `reactorCallback` and read back in `_conductSwap`.
    bytes32 private constant RESOLVED_INPUT_SLOT = 0x2f4a6c8e0a2c4e6f8a0c2e4f6a8c0e2f4a6c8e0a2c4e6f8a0c2e4f6a8c0e2f4b;
    bytes32 private constant RESOLVED_OUTPUT_SLOT = 0x3a5c7e9b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5d;

    /// @dev Upper bound for order amounts. The V4 swap delta is formed via `int128(uint128(amount))` in the
    ///      base `_processAmounts`, so any amount above `int128.max` would silently sign-flip/truncate the
    ///      delta. Both the order input and (summed) output are validated against this before being used.
    uint256 private constant MAX_INT128 = uint256(uint128(type(int128).max));

    error Reentrancy();
    error ProhibitedEntry();
    error UnauthorizedCaller();
    error NoOrderData();
    error NoOrderOutputs();
    error InconsistentOrderOutputs();
    error OrderInputMismatch();
    error OrderOutputMismatch();
    error OrderAmountMismatch();
    error OrderInputOverflow();
    error OrderOutputOverflow();
    error NativeTransferFailed();
    error TVLNotSupported();

    constructor(IPoolManager _manager, IReactor _reactor, address _weth)
        BaseHookDataAggregator(_manager, "UniswapXAggregator v1.0")
    {
        reactor = _reactor;
        weth = _weth;
        orderQuoter = new OrderQuoter();
    }

    function protocolFeeFlags() external pure override returns (uint256) {
        return 0;
    }

    /// @inheritdoc BaseHookDataAggregator
    /// @dev Resolves the order in `hookData` (Dutch decay applied) via the OrderQuoter and returns the amount on
    ///      the side opposite `amountSpecified`. The order fully determines both amounts, so `zeroToOne`/`poolId`
    ///      are unused. NOTE: like UniswapX's OrderQuoter this is NOT a view — it calls the reactor (pulling the
    ///      maker's input via Permit2 before rolling back), so it requires a funded, approved, validly-signed order
    ///      and cannot be `staticcall`-ed.
    function _rawQuoteWithHookData(bool, int256 amountSpecified, PoolId, bytes calldata hookData)
        internal
        override
        returns (uint256 amountUnspecified)
    {
        if (hookData.length == 0) revert NoOrderData();
        SignedOrder memory order = abi.decode(hookData, (SignedOrder));

        ResolvedOrder memory resolved = orderQuoter.quote(order.order, order.sig);

        // Sum the order's outputs. The fill requires all outputs share one token (the V4 swapper's input
        // currency), so enforce that same-token invariant here too — otherwise a quote could return a
        // meaningless sum across differing tokens that `reactorCallback` would later reject at fill time.
        if (resolved.outputs.length == 0) revert NoOrderOutputs();
        address outputToken = resolved.outputs[0].token;
        uint256 orderOutput;
        for (uint256 i = 0; i < resolved.outputs.length; i++) {
            if (resolved.outputs[i].token != outputToken) revert InconsistentOrderOutputs();
            orderOutput += resolved.outputs[i].amount;
        }

        // Mirror the execution-time `int128` narrowing (see MAX_INT128) so a quote never returns an amount
        // that `_conductSwap` would later reject as overflowing.
        if (orderOutput > MAX_INT128) revert OrderOutputOverflow();
        if (resolved.input.amount > MAX_INT128) revert OrderInputOverflow();

        // Exact-in: the V4 swap input is `-amountSpecified` (in the order's output token); reject if it is
        // less than the order's output, since the all-or-nothing fill could not be covered.
        if (amountSpecified < 0 && amountSpecified > -int256(orderOutput)) revert OrderAmountMismatch();
        // Exact-out: the V4 swapper requests `amountSpecified` of the order's input token; reject if it
        // exceeds what the order supplies.
        if (amountSpecified > 0 && amountSpecified > int256(resolved.input.amount)) revert OrderAmountMismatch();

        // The hook fills atomically: the V4 swapper provides the order's OUTPUT and receives its INPUT.
        // exact-in  (amountSpecified < 0): swapper specified the input it provides (order output) -> receives order input
        // exact-out (amountSpecified > 0): swapper specified the output it wants (order input)   -> pays order output
        return amountSpecified < 0 ? resolved.input.amount : orderOutput;
    }

    /// @inheritdoc IReactorCallback
    /// @dev Called by the reactor mid-execution. Sources the order's output from the PoolManager (the V4
    ///      swapper's input), converting between native ETH and WETH as needed.
    function reactorCallback(ResolvedOrder[] memory resolvedOrders, bytes memory callbackData) external override {
        if (!_getTransientInflight()) revert ProhibitedEntry();
        if (msg.sender != address(reactor)) revert UnauthorizedCaller();

        (Currency settleCurrency, Currency takeCurrency) = abi.decode(callbackData, (Currency, Currency));

        ResolvedOrder memory resolved = resolvedOrders[0];

        // The order's input token (received by this hook) must correspond to the V4 swapper's output currency.
        if (!_matches(settleCurrency, address(resolved.input.token))) revert OrderInputMismatch();

        // Sum the order's outputs; all outputs must share the same token and correspond to the take currency.
        if (resolved.outputs.length == 0) revert NoOrderOutputs();
        address outputToken = resolved.outputs[0].token;
        if (!_matches(takeCurrency, outputToken)) revert OrderOutputMismatch();
        uint256 outputAmount;
        for (uint256 i = 0; i < resolved.outputs.length; i++) {
            if (resolved.outputs[i].token != outputToken) revert InconsistentOrderOutputs();
            outputAmount += resolved.outputs[i].amount;
        }

        // Pull the V4 swapper's input from the PoolManager into this hook (native ETH or ERC20).
        poolManager.take(takeCurrency, address(this), outputAmount);

        // Convert what we hold into the order's output token so the reactor can deliver it.
        if (outputToken == address(0)) {
            // Order pays native ETH: ensure we hold ETH, then forward it to the reactor (it pays the
            // recipient from its own balance after this callback returns).
            if (!takeCurrency.isAddressZero()) IWETH9(weth).withdraw(outputAmount);
            (bool ok,) = address(reactor).call{value: outputAmount}("");
            if (!ok) revert NativeTransferFailed();
        } else if (outputToken == weth) {
            // Order pays WETH: ensure we hold WETH (wrap if we took native ETH). The reactor pulls it via approval.
            if (takeCurrency.isAddressZero()) IWETH9(weth).deposit{value: outputAmount}();
        }
        // Otherwise the order's output is an ordinary ERC20 equal to `takeCurrency`; the reactor pulls it via approval.

        _setTransientResolved(RESOLVED_INPUT_SLOT, resolved.input.amount);
        _setTransientResolved(RESOLVED_OUTPUT_SLOT, outputAmount);
    }

    /// @inheritdoc BaseAggregatorHook
    /// @dev No persistent liquidity exists; TVL is undefined for an order-filling hook.
    function pseudoTotalValueLocked(PoolId) external pure override returns (uint256, uint256) {
        revert TVLNotSupported();
    }

    /// @notice Returns true if `token` represents native ETH on the order side, accounting for WETH equivalence
    function _isEthClass(address token) internal view returns (bool) {
        return token == address(0) || token == weth;
    }

    /// @notice Returns true if a V4 currency corresponds to an order-side token, treating ETH and WETH as equivalent
    function _matches(Currency currency, address orderToken) internal view returns (bool) {
        address unwrapped = Currency.unwrap(currency);
        if (unwrapped == orderToken) return true;
        return _isEthClass(unwrapped) && _isEthClass(orderToken);
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        registered[key.toId()] = true;

        // The Reactor pulls the order's output token from this hook via transferFrom, so it must be approved.
        // Approve each non-native currency, plus WETH whenever a side is native (a native V4 currency may map
        // to a WETH order output).
        if (!key.currency0.isAddressZero()) {
            IERC20(Currency.unwrap(key.currency0)).forceApprove(address(reactor), type(uint256).max);
        }
        if (!key.currency1.isAddressZero()) {
            IERC20(Currency.unwrap(key.currency1)).forceApprove(address(reactor), type(uint256).max);
        }
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) {
            IERC20(weth).forceApprove(address(reactor), type(uint256).max);
        }

        emit AggregatorPoolRegistered(key.toId());
        pollTokenJar();
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc BaseHookDataAggregator
    /// @dev The swap's hookData is the ABI-encoded UniswapX SignedOrder to fill.
    function _conductSwap(
        Currency settleCurrency,
        Currency takeCurrency,
        SwapParams calldata params,
        PoolId,
        bytes calldata hookData
    ) internal override returns (uint256 amountSettle, uint256 amountTake, bool hasSettled) {
        if (_getTransientInflight()) revert Reentrancy();
        if (hookData.length == 0) revert NoOrderData();

        SignedOrder memory order = abi.decode(hookData, (SignedOrder));

        _setTransientInflight(true);

        // Execute the order. The reactor pulls the order swapper's input (ERC20) to this hook, calls
        // `reactorCallback` (where we source and convert the order's output from the PoolManager), then
        // transfers the order's output from this hook to the order's recipient.
        reactor.executeWithCallback(order, abi.encode(settleCurrency, takeCurrency));

        _setTransientInflight(false);

        // amountSettle = order input amount (now held by this hook, in `settleCurrency` units after any unwrap)
        // amountTake   = order output amount (taken from the PoolManager in the callback)
        amountSettle = _getTransientResolved(RESOLVED_INPUT_SLOT);
        amountTake = _getTransientResolved(RESOLVED_OUTPUT_SLOT);

        // Guard the true narrowing site: both amounts are cast to int128 when the base forms the swap delta.
        // Above int128.max the cast silently sign-flips/truncates, so reject here before that happens.
        if (amountTake > MAX_INT128) revert OrderOutputOverflow();
        if (amountSettle > MAX_INT128) revert OrderInputOverflow();

        // If the V4 swapper's output is native ETH but the order paid us WETH, unwrap so the base can settle ETH.
        if (settleCurrency.isAddressZero()) {
            uint256 wethBalance = IWETH9(weth).balanceOf(address(this));
            if (wethBalance != 0) IWETH9(weth).withdraw(wethBalance);
        }

        // Enforce the all-or-nothing match: the V4 swap amount must equal the resolved order amount.
        if (params.amountSpecified < 0) {
            if (amountTake != uint256(-params.amountSpecified)) revert OrderAmountMismatch();
        } else {
            if (amountSettle != uint256(params.amountSpecified)) revert OrderAmountMismatch();
        }

        // Leave the order's input token in this hook so the base `_internalSettle` settles `settleCurrency`.
        return (amountSettle, amountTake, false);
    }

    function _setTransientInflight(bool value) private {
        uint256 _value = value ? 1 : 0;
        assembly {
            tstore(INFLIGHT_SLOT, _value)
        }
    }

    function _getTransientInflight() private view returns (bool value) {
        uint256 _value;
        assembly {
            _value := tload(INFLIGHT_SLOT)
        }
        value = _value > 0;
    }

    function _setTransientResolved(bytes32 slot, uint256 value) private {
        assembly {
            tstore(slot, value)
        }
    }

    function _getTransientResolved(bytes32 slot) private view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }
}
