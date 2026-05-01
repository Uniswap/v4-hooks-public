// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BaseALFHook} from "./BaseALFHook.sol";
import {SwapSimulator} from "../libraries/SwapSimulator.sol";

/// @title SpreadQuoterBase
/// @author Uniswap Labs
/// @notice Abstract base for spread quoters using native v4 LP with a static, per-pool fee.
///         Provides pricing via SwapSimulator and single-tick LP concentration. Concrete
///         hooks define LP access control and hook permissions.
/// @dev    Pools use a static fee defined by `PoolKey.fee` at deploy time. The v4 PoolManager
///         charges this fee natively on every swap. Owner has only a per-pool liveness flag
///         (`setPoolLive`) for pause/resume; pricing itself is immutable post-initialize.
/// @custom:security-contact security@uniswap.org
abstract contract SpreadQuoterBase is BaseALFHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    /// @notice Whether each pool is currently quoting and executing swaps. Pools default to
    ///         paused (`false`) after `manager.initialize`; the owner enables them via
    ///         {setPoolLive}.
    mapping(PoolId => bool) public livePools;

    /// @notice Lower tick of the single permitted LP range per pool. LP add liquidity calls
    ///         must use exactly `[activeLowerTick, activeLowerTick + tickSpacing]`.
    mapping(PoolId => int24) public activeLowerTick;

    /// @notice Emitted when a pool's liveness flag is toggled via `setPoolLive`.
    /// @param poolId The pool whose liveness changed.
    /// @param isLive The new liveness state.
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);

    /// @notice Emitted when the active lower tick is changed via `setActiveTick` or
    ///         `_afterInitialize`.
    /// @param poolId           The pool whose active range changed.
    /// @param activeLowerTick  The new lower tick (always aligned to `tickSpacing`).
    event ActiveTickUpdated(PoolId indexed poolId, int24 activeLowerTick);

    /// @dev LP add-liquidity range is malformed (lower >= upper, not aligned to `tickSpacing`,
    ///      or the range width does not equal one tickSpacing).
    error InvalidTickRange();
    /// @dev LP add-liquidity range is correctly shaped but not at the configured `activeLowerTick`.
    error WrongActiveTick();

    /// @dev `_beforeSwap` was invoked on a pool whose `livePools` flag is false. Pools default
    ///      to paused after `manager.initialize`; the owner enables a pool via {setPoolLive}.
    /// @param poolId The pool whose live flag is currently false.
    error PoolNotLive(PoolId poolId);

    /// @dev Direct `poolManager.initialize` for any SpreadQuoter-hooked pool is rejected;
    ///      callers MUST go through the subclass's owner-only `initializePool` entry point so
    ///      the pool's `sqrtPriceX96` (immutable post-init) cannot be front-run by a third
    ///      party at a price the operator did not choose.
    error DirectInitializeBlocked();

    /// @dev The PoolKey's hooks address does not match this contract — `initializePool` was
    ///      called with a key intended for a different hook.
    error InvalidHookAddress();

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param maxGas_      Gas budget declared for `getIndicativeQuote` staticcalls.
    /// @param owner_       Initial owner (Ownable2Step). Owner can toggle liveness and the active tick.
    constructor(IPoolManager _poolManager, uint32 maxGas_, address owner_)
        BaseALFHook(_poolManager, maxGas_)
        Ownable(owner_)
    {}

    // ──── IALFHook ────

    /// @notice Always reports live; per-pool liveness is gated by `livePools[poolId]`.
    /// @dev    See {IALFHook.isLive}. Routers SHOULD also consult per-pool liveness for swap
    ///         eligibility.
    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @notice Indicative quote against the static pool fee.
    /// @dev Resolves attestation from hookData; the pool's static `key.fee` drives pricing.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        (bool isAttested, address attester) = _resolveHookData(hookData);
        return _price(key, zeroForOne, amountSpecified, isAttested, attester);
    }

    /// @notice Simulate a swap up to a target price, returning both amounts.
    /// @dev Delegates to `SwapSimulator.simulateSwapToPrice` using `key.fee`.
    function swapToPrice(
        PoolKey calldata key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata
    ) external view virtual override returns (uint256 amountIn, uint256 amountOut) {
        if (!livePools[key.toId()]) return (0, 0);

        return SwapSimulator.simulateSwapToPrice(
            poolManager, key.toId(), zeroForOne, amountSpecified, key.fee, key.tickSpacing, sqrtPriceLimitX96
        );
    }

    // ──── Hook Lifecycle ────

    /// @dev Reject direct `poolManager.initialize`. Per v4 `Hooks.noSelfCall`, the hook's own
    ///      `poolManager.initialize` from `initializePool` skips this callback, so the only
    ///      caller path that reaches here is an external party's direct attempt. Without this
    ///      gate, anyone could front-run an operator-planned launch and pin the pool's
    ///      `sqrtPriceX96` (immutable post-init) to a price the operator did not choose.
    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert DirectInitializeBlocked();
    }

    /// @notice Initialize a new SpreadQuoter pool at the operator's chosen price.
    /// @dev    `onlyOwner`-gated and routes through `poolManager.initialize` so v4's
    ///         `Hooks.noSelfCall` exempts the call from `_beforeInitialize`'s revert. The pool
    ///         starts paused (`livePools[id] == false`); enable via {setPoolLive} after
    ///         seeding LP at the auto-derived active tick.
    /// @param key            The PoolKey (must reference this hook).
    /// @param sqrtPriceX96   Initial sqrt price (Q64.96). This price is permanent for the pool's
    ///                       lifetime.
    /// @return tick          The initial tick assigned by the PoolManager.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external onlyOwner returns (int24 tick) {
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        return poolManager.initialize(key, sqrtPriceX96);
    }

    /// @dev Auto-derive the active lower tick from the initial pool tick at initialization.
    ///      Floor-aligns to `tickSpacing` and clamps to the v4 usable tick range so the
    ///      resulting LP range `[activeLowerTick, activeLowerTick + tickSpacing]` is always
    ///      a valid v4 LP position — even at the extremes near MIN/MAX_TICK.
    ///      Emits no event — `setActiveTick` is the canonical source for `ActiveTickUpdated`
    ///      events post-init.
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        // Auto-set active tick aligned to tickSpacing (floor division)
        int24 compressed = tick / key.tickSpacing;
        if (tick < 0 && tick % key.tickSpacing != 0) compressed--;
        int24 candidate = compressed * key.tickSpacing;

        // Clamp into [minUsableTick, maxUsableTick - tickSpacing] so the LP range fits.
        int24 minUsable = TickMath.minUsableTick(key.tickSpacing);
        int24 maxLower = TickMath.maxUsableTick(key.tickSpacing) - key.tickSpacing;
        if (candidate < minUsable) candidate = minUsable;
        else if (candidate > maxLower) candidate = maxLower;

        activeLowerTick[key.toId()] = candidate;

        return IHooks.afterInitialize.selector;
    }

    /// @dev Reverts when the pool is paused; otherwise no-ops. v4 charges the static fee from
    ///      `key.fee`, so no override is returned. hookData is ignored; pricing is fully static.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        view
        virtual
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        if (!livePools[poolId]) revert PoolNotLive(poolId);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ──── Pricing ────

    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool, address)
        internal
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        if (!livePools[key.toId()]) return 0;
        outputAmount =
            SwapSimulator.simulateSwap(poolManager, key.toId(), zeroForOne, amountSpecified, key.fee, key.tickSpacing);
    }

    // ──── LP Tick Enforcement ────

    /// @dev Enforce single-tick-spacing LP at the active tick.
    function _enforceActiveTick(PoolKey calldata key, ModifyLiquidityParams calldata params) internal view {
        if (params.tickUpper - params.tickLower != key.tickSpacing) revert InvalidTickRange();
        if (params.tickLower != activeLowerTick[key.toId()]) revert WrongActiveTick();
    }

    // ──── Owner Functions ────

    /// @notice Toggle liveness for a pool.
    /// @dev Pools default to paused (`false`) immediately after `manager.initialize`. The
    ///      owner enables a pool by calling `setPoolLive(key, true)`. Disabling pauses swaps
    ///      via `_beforeSwap`'s liveness check; pricing (the static `key.fee`) is unaffected.
    function setPoolLive(PoolKey calldata key, bool live) external virtual onlyOwner {
        livePools[key.toId()] = live;
        emit PoolLivenessUpdated(key.toId(), live);
    }

    /// @notice Set the active lower tick for LP concentration.
    function setActiveTick(PoolKey calldata key, int24 newActiveLowerTick) external virtual onlyOwner {
        if (newActiveLowerTick % key.tickSpacing != 0) revert InvalidTickRange();
        activeLowerTick[key.toId()] = newActiveLowerTick;
        emit ActiveTickUpdated(key.toId(), newActiveLowerTick);
    }
}
