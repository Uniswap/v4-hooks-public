// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {BaseALFHook} from "./base/BaseALFHook.sol";

/// @title Permit2JITQuoterHook
/// @notice JIT (just-in-time) liquidity quoter that pulls tokens from a maker's wallet via Permit2,
///         adds concentrated LP in beforeSwap, lets the AMM execute against it, then removes the LP
///         in afterSwap and returns tokens to the maker as ERC-20. Pricing is controlled via fee overrides.
/// @dev The hook checks the PoolManager's ERC-20 balance before providing JIT LP. If PM doesn't have
///      enough float to guarantee full ERC-20 settlement to the maker, the hook refuses to quote —
///      ensuring the maker never receives ERC-6909 claims.
contract Permit2JITQuoterHook is BaseALFHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencyLibrary for Currency;

    IAllowanceTransfer public immutable permit2;

    /// @dev Salt used for all JIT LP positions (distinguishes from other positions on the same pool).
    bytes32 public constant JIT_SALT = bytes32(uint256(0x4a4954)); // "JIT"

    struct JITConfig {
        address maker; // Wallet holding capital (has Permit2 approval → this hook)
        uint128 bidCoefficient; // Indicative quote coefficient for zeroForOne (1e18)
        uint128 askCoefficient; // Indicative quote coefficient for oneForZero (1e18)
        uint24 bidFeePips; // Fee override for zeroForOne swaps
        uint24 askFeePips; // Fee override for oneForZero swaps
        int24 tickWidth; // Half-width for JIT LP range (in ticks, before alignment)
        uint128 liquidity; // Liquidity units to add per swap
        uint16 attestedDiscountBps; // Discount for attested indicative quotes
        bool live;
    }

    mapping(PoolId => JITConfig) public jitConfig;

    // ──── Transient storage for per-swap JIT position ────

    // Using explicit slots avoids collision with inherited storage
    uint256 private constant _TSTORE_TICK_LOWER = uint256(keccak256("Permit2JITQuoterHook.tickLower"));
    uint256 private constant _TSTORE_TICK_UPPER = uint256(keccak256("Permit2JITQuoterHook.tickUpper"));
    uint256 private constant _TSTORE_LIQUIDITY = uint256(keccak256("Permit2JITQuoterHook.liquidity"));

    event JITConfigUpdated(PoolId indexed poolId, JITConfig config);
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);

    constructor(
        IPoolManager _poolManager,
        IAllowanceTransfer _permit2,
        uint32 maxGas_,
        address owner_
    ) BaseALFHook(_poolManager, maxGas_) Ownable(owner_) {
        permit2 = _permit2;
    }

    // ──── Hook Permissions ────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // register in index
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // add JIT LP + fee override
            afterSwap: true, // remove JIT LP + return tokens to maker
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──── IALFHook ────

    function isLive() external view override returns (bool) {
        return true;
    }

    // ──── Hook Lifecycle ────

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        JITConfig memory config = jitConfig[poolId];

        if (!config.live || config.liquidity == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 0. Guarantee ERC-20 settlement: check that PM has enough float in the input token
        //    to cover the swap's contribution when LP is removed in afterSwap.
        //    If not, refuse to provide JIT LP — the maker must never receive claims.
        {
            Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            uint256 swapSize =
                params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            if (_pmBalance(inputCurrency) < swapSize) {
                return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
            }
        }

        // 1. Compute tick range centered on current price
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        (int24 tickLower, int24 tickUpper) = _computeTickRange(currentTick, config.tickWidth, key.tickSpacing);

        // Validate tick range is usable
        if (tickLower >= tickUpper || sqrtPriceX96 == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        // 2. Add JIT LP — delta is accounted to this hook (noSelfCall skips hook callbacks)
        (BalanceDelta lpDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(config.liquidity)),
                salt: JIT_SALT
            }),
            ""
        );

        // 3. Settle LP delta — pull tokens from maker via Permit2 and pay PM
        _settleAddLPDelta(key, config.maker, lpDelta);

        // 4. Store position in transient storage for afterSwap
        _tstore(_TSTORE_TICK_LOWER, uint256(int256(tickLower)));
        _tstore(_TSTORE_TICK_UPPER, uint256(int256(tickUpper)));
        _tstore(_TSTORE_LIQUIDITY, uint256(config.liquidity));

        // 5. Return fee override
        uint24 feePips = params.zeroForOne ? config.bidFeePips : config.askFeePips;
        uint24 feeOverride = feePips | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeOverride);
    }

    function _afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        // 1. Load JIT position from transient storage
        uint128 liquidity = uint128(_tload(_TSTORE_LIQUIDITY));
        if (liquidity == 0) return (IHooks.afterSwap.selector, 0);

        int24 tickLower = int24(int256(_tload(_TSTORE_TICK_LOWER)));
        int24 tickUpper = int24(int256(_tload(_TSTORE_TICK_UPPER)));

        JITConfig memory config = jitConfig[key.toId()];

        // 2. Remove JIT LP — delta is positive (hook receives tokens back)
        (BalanceDelta lpDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: -int256(uint256(liquidity)), salt: JIT_SALT
            }),
            ""
        );

        // 3. Take all as ERC-20 directly to maker.
        //    Safe because beforeSwap verified PM has enough float. If this somehow
        //    fails (e.g., concurrent drain), the entire swap reverts atomically.
        int128 delta0 = lpDelta.amount0();
        int128 delta1 = lpDelta.amount1();
        if (delta0 > 0) _take(key.currency0, config.maker, uint256(int256(delta0)));
        if (delta1 > 0) _take(key.currency1, config.maker, uint256(int256(delta1)));

        // 4. Clear transient storage
        _tstore(_TSTORE_TICK_LOWER, 0);
        _tstore(_TSTORE_TICK_UPPER, 0);
        _tstore(_TSTORE_LIQUIDITY, 0);

        return (IHooks.afterSwap.selector, 0);
    }

    // ──── Pricing (non-binding indicative quotes) ────

    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool isAttested, address)
        internal
        view
        override
        returns (uint256 outputAmount)
    {
        JITConfig memory config = jitConfig[key.toId()];
        if (!config.live) return 0;

        uint256 amount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 coefficient = zeroForOne ? config.bidCoefficient : config.askCoefficient;

        outputAmount = (amount * coefficient) / 1e18;

        if (isAttested && config.attestedDiscountBps > 0) {
            outputAmount = (outputAmount * (10_000 + config.attestedDiscountBps)) / 10_000;
        }
    }

    // ──── Owner Functions ────

    /// @notice Update the JIT configuration for a pool.
    function updateJITConfig(PoolKey calldata key, JITConfig calldata config) external onlyOwner {
        jitConfig[key.toId()] = config;
        emit JITConfigUpdated(key.toId(), config);
    }

    /// @notice Toggle liveness for a pool.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner {
        jitConfig[key.toId()].live = live;
        emit PoolLivenessUpdated(key.toId(), live);
    }

    // ──── Internal Helpers ────

    /// @dev Compute tick range centered on currentTick, aligned to tickSpacing.
    function _computeTickRange(int24 currentTick, int24 tickWidth, int24 tickSpacing)
        internal
        pure
        returns (int24 tickLower, int24 tickUpper)
    {
        // Round down to nearest tickSpacing
        tickLower = ((currentTick - tickWidth) / tickSpacing) * tickSpacing;
        tickUpper = ((currentTick + tickWidth) / tickSpacing) * tickSpacing;
        // Ensure upper > lower (if tickWidth < tickSpacing, both might round to same value)
        if (tickUpper <= tickLower) {
            tickUpper = tickLower + tickSpacing;
        }
    }

    /// @dev After adding LP, hook owes tokens to PM. Pull from maker via Permit2 and settle.
    function _settleAddLPDelta(PoolKey calldata key, address maker, BalanceDelta lpDelta) internal {
        int128 delta0 = lpDelta.amount0();
        int128 delta1 = lpDelta.amount1();

        // Adding LP creates negative delta (hook owes tokens to PM)
        if (delta0 < 0) {
            uint256 amount = uint256(int256(-delta0));
            permit2.transferFrom(maker, address(this), uint160(amount), Currency.unwrap(key.currency0));
            _settle(key.currency0, address(this), amount);
        }
        if (delta1 < 0) {
            uint256 amount = uint256(int256(-delta1));
            permit2.transferFrom(maker, address(this), uint160(amount), Currency.unwrap(key.currency1));
            _settle(key.currency1, address(this), amount);
        }
    }

    /// @dev Check the PoolManager's ERC-20 balance for a given currency.
    function _pmBalance(Currency currency) internal view returns (uint256) {
        if (currency.isAddressZero()) return address(poolManager).balance;
        return IERC20Minimal(Currency.unwrap(currency)).balanceOf(address(poolManager));
    }

    // ──── Transient Storage Helpers (Cancun EVM) ────

    function _tstore(uint256 slot, uint256 value) internal {
        assembly {
            tstore(slot, value)
        }
    }

    function _tload(uint256 slot) internal view returns (uint256 value) {
        assembly {
            value := tload(slot)
        }
    }
}
