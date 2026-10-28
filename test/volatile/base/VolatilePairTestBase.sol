// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatileFuzzTestBase} from "./VolatileFuzzTestBase.sol";
import {VolatilePairHook} from "../../../src/volatile/VolatilePairHook.sol";
import {BaseDynamicFeeHook} from "../../../src/base/BaseDynamicFeeHook.sol";
import {VolatileFeeConfig, VolatileFeeState} from "../../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
// Imported only so forge builds the artifact `deployCodeTo` loads by name.
import {ERC1967Proxy as _ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// Acts as the hook's PoolManager: `initialize` is a stub, `extsload` serves `sqrtAmmPriceX96`.
abstract contract VolatilePairTestBase is VolatileFuzzTestBase {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant RESTING_SPREAD_E6 = 900;
    uint24 internal constant BACKRUN_CAPTURE_FRACTION_E6 = 500_000;
    uint24 internal constant MID_FADE_RATE_E6 = 50_000;
    uint24 internal constant MAX_MID_FADE_E6 = 200;
    uint24 internal constant SKEW_RATE_E6 = 100_000;
    uint24 internal constant MAX_SKEW_STEP_E6 = 300;
    uint24 internal constant MAX_SKEW_E6 = 900; // = RS, the top of the legal band
    uint24 internal constant BACKRUN_THRESHOLD_E6 = 1_000;

    uint24 internal constant NEUTRAL_FEE_E6 = RESTING_SPREAD_E6 / 2;

    /// Ethereum's value: only the block right after the previous block open pays the temp fee.
    uint256 internal constant MAX_TEMP_FEE_BLOCK_GAP = 1;

    int24 internal constant TICK_SPACING = 60;

    /// ERC-7201 base slot of `VolatileFeeConfiguration`.
    bytes32 internal constant FEE_CONFIGURATION_BASE_SLOT =
        0x5d4cd891dc52dbf2064bf3b556cd164a438eebc4f9a9ba71ffb5a8f1380e1e00;

    uint160 internal constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
    );

    VolatilePairHook public hook;

    address internal configManager = makeAddr("configManager");
    address internal poolInitializer = makeAddr("poolInitializer");
    address internal owner = makeAddr("owner");
    uint160 internal sqrtAmmPriceX96 = Constants.SQRT_PRICE_1_1;
    PoolKey internal testPoolKey;

    struct SwapStep {
        bool zeroForOne;
        uint160 priceSeed;
        uint32 blockGap;
    }

    function setUp() public virtual {
        VolatilePairHook impl = new VolatilePairHook(IPoolManager(address(this)), MAX_TEMP_FEE_BLOCK_GAP);
        address proxyAddress = address((uint160(type(uint160).max) & ~Hooks.ALL_HOOK_MASK) | HOOK_FLAGS);
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, configManager))
            ),
            proxyAddress
        );
        hook = VolatilePairHook(proxyAddress);

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        VolatileFeeConfig memory initialConfig = _initialConfig();
        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, initialConfig);
    }

    function _defaultConfig() internal pure returns (VolatileFeeConfig memory) {
        return VolatileFeeConfig({
            restingSpreadE6: RESTING_SPREAD_E6,
            backrunCaptureFractionE6: BACKRUN_CAPTURE_FRACTION_E6,
            midFadeRateE6: MID_FADE_RATE_E6,
            maxMidFadeE6: MAX_MID_FADE_E6,
            skewRateE6: SKEW_RATE_E6,
            maxSkewStepE6: MAX_SKEW_STEP_E6,
            maxSkewE6: MAX_SKEW_E6,
            backrunThresholdE6: BACKRUN_THRESHOLD_E6,
            restoreFractionE6: RESTORE_FRACTION_E6,
            restoreThresholdE6: RESTORE_THRESHOLD_E6
        });
    }

    function _initialConfig() internal virtual returns (VolatileFeeConfig memory) {
        return _defaultConfig();
    }

    /// Valid for RS in [MAX_SKEW_STEP_E6, MAX_FEE_E6]: with maxSkew = RS the step band 2 * maxSkew - RS is RS,
    /// which must still hold the default step.
    function _configWithRestingSpread(uint24 restingSpreadE6) internal pure returns (VolatileFeeConfig memory c) {
        c = _defaultConfig();
        c.restingSpreadE6 = restingSpreadE6;
        c.maxSkewE6 = restingSpreadE6;
    }

    // -------------------------------------------------------------------------
    // Fuzz generators
    // -------------------------------------------------------------------------

    function _boundSqrtPriceAbsolute(uint160 seed) internal pure returns (uint160) {
        return uint160(bound(uint256(seed), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
    }

    /// A sqrt price whose PRICE is within 0.90x..1.10x of `refSqrtPrice`.
    function _boundSqrtPriceRelative(uint160 seed, uint160 refSqrtPrice) internal pure returns (uint160) {
        uint256 priceE6 = bound(uint256(seed), 900_000, 1_100_000);
        // factorE6 = sqrt(priceE6/1e6) * 1e6
        uint256 factorE6 = FixedPointMathLib.sqrt(priceE6 * 1e6);
        uint256 sqrtAmm = uint256(refSqrtPrice) * factorE6 / 1e6;
        if (sqrtAmm < uint256(TickMath.MIN_SQRT_PRICE)) sqrtAmm = uint256(TickMath.MIN_SQRT_PRICE);
        if (sqrtAmm >= uint256(TickMath.MAX_SQRT_PRICE)) sqrtAmm = uint256(TickMath.MAX_SQRT_PRICE) - 1;
        return uint160(sqrtAmm);
    }

    // -------------------------------------------------------------------------
    // PoolManager mock
    // -------------------------------------------------------------------------

    function initialize(PoolKey calldata, uint160) external pure returns (int24) {
        return 0;
    }

    function extsload(bytes32 slot) external view virtual returns (bytes32) {
        assertEq(slot, StateLibrary._getPoolStateSlot(testPoolKey.toId()));
        return _packedSlot0(sqrtAmmPriceX96);
    }

    /// slot0 with its non-price fields populated, so an unmasked price read is caught.
    function _packedSlot0(uint160 sqrtPriceX96) internal pure returns (bytes32) {
        return bytes32(uint256(sqrtPriceX96) | ((0x000000_000bb8_000000_ffff75) << 160));
    }

    // -------------------------------------------------------------------------
    // Shared helpers
    // -------------------------------------------------------------------------

    /// A sqrt price whose PRICE is `priceRatioE6`/1e6 of `refSqrtPriceX96`; sqrt space, so ref^2 can't overflow.
    function _sqrtPriceScaled(uint160 refSqrtPriceX96, uint256 priceRatioE6) internal pure returns (uint160) {
        uint256 factorE6 = FixedPointMathLib.sqrt(priceRatioE6 * 1e6); // sqrt(priceRatioE6/1e6) scaled by 1e6
        return uint160(uint256(refSqrtPriceX96) * factorE6 / 1e6);
    }

    function _setConfig(VolatileFeeConfig memory config) internal {
        vm.prank(configManager);
        hook.updateFeeConfig(testPoolKey.toId(), config);
    }

    function _setAmmPrice(uint160 sqrtPriceX96) internal {
        sqrtAmmPriceX96 = sqrtPriceX96;
    }

    function _advanceBlocks(uint256 blocks) internal {
        vm.roll(block.number + blocks);
    }

    /// `feeConfig` is the namespaced struct's first member, so its mapping hashes from the base slot itself.
    function _configSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, FEE_CONFIGURATION_BASE_SLOT));
    }

    /// `feeState` is the second member: base + 1.
    function _stateSlot(PoolId poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, uint256(FEE_CONFIGURATION_BASE_SLOT) + 1));
    }

    /// Both raw per-pool words (state and config); catches fields `feeState` omits.
    function _rawStateHash(PoolId poolId) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(vm.load(address(hook), _stateSlot(poolId)), vm.load(address(hook), _configSlot(poolId)))
            );
    }

    /// Ten return words run the stack too deep when assigned field by field.
    function _storedConfig(PoolId poolId) internal view returns (VolatileFeeConfig memory) {
        (, bytes memory data) = address(hook).staticcall(abi.encodeCall(hook.feeConfig, (poolId)));
        return abi.decode(data, (VolatileFeeConfig));
    }

    function _storedState(PoolId poolId) internal view returns (VolatileFeeState memory s) {
        (s.blockNumber, s.sqrtPriceTopX96, s.askPermFeeE6, s.tempFeeE6, s.tempOnBid) = hook.feeState(poolId);
    }

    /// Baselines are not stored; derived from the stored skew and temp fee the way `_getFee` derives them.
    function _storedBaselines(PoolId poolId) internal view returns (uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) {
        (uint24 restingSpreadE6,,,,,,,,,) = hook.feeConfig(poolId);
        return _baselines(_storedState(poolId), restingSpreadE6);
    }
}
