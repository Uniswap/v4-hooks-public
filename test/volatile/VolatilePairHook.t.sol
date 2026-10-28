// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatilePairTestBase} from "./base/VolatilePairTestBase.sol";
import {VolatilePairHook} from "../../src/volatile/VolatilePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {IVolatilePairHook} from "../../src/volatile/interfaces/IVolatilePairHook.sol";
import {IDynamicFeeHook} from "../../src/interfaces/IDynamicFeeHook.sol";
import {
    IVolatileFeeConfiguration,
    VolatileFeeConfig,
    VolatileFeeState
} from "../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {ImmutableState} from "@uniswap/v4-periphery/src/base/ImmutableState.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// VolatilePairHook through its `ERC1967Proxy` against a real PoolManager. `setUp` leaves `testPoolKey` uninitialized.
contract VolatilePairHookTest is VolatilePairTestBase, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    VolatilePairHook internal impl;
    address internal other = makeAddr("other");
    PoolKey internal unusedPoolKey;

    function setUp() public override {
        deployFreshManagerAndRouters();

        impl = new VolatilePairHook(manager, MAX_TEMP_FEE_BLOCK_GAP);

        hook = VolatilePairHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | HOOK_FLAGS)));
        deployCodeTo(
            "ERC1967Proxy.sol:ERC1967Proxy",
            abi.encode(
                address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (owner, poolInitializer, configManager))
            ),
            address(hook)
        );

        testPoolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        unusedPoolKey = testPoolKey;
        unusedPoolKey.fee = 3000;
        unusedPoolKey.hooks = IHooks(address(0));
    }

    function _initializeTestPool() internal {
        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    /// Odd pie: resets to ask 500 / bid 501, so a swapped pair fails.
    function _distinctConfig() internal pure returns (VolatileFeeConfig memory) {
        return VolatileFeeConfig({
            restingSpreadE6: 1001,
            backrunCaptureFractionE6: 250_000,
            midFadeRateE6: 30_000,
            maxMidFadeE6: 111,
            skewRateE6: 77_000,
            maxSkewStepE6: 222,
            maxSkewE6: 800, // in [ceil(1001/2), 1001]
            backrunThresholdE6: 1234,
            restoreFractionE6: 333_333,
            restoreThresholdE6: 4321
        });
    }

    function test_initialize_grantsRolesToDistinctAddresses() public view {
        assertTrue(hook.hasRole(hook.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(hook.hasRole(hook.POOL_INITIALIZER_ROLE(), poolInitializer));
        assertTrue(hook.hasRole(hook.CONFIG_MANAGER_ROLE(), configManager));

        assertFalse(hook.hasRole(hook.POOL_INITIALIZER_ROLE(), owner));
        assertFalse(hook.hasRole(hook.POOL_INITIALIZER_ROLE(), configManager));
        assertFalse(hook.hasRole(hook.CONFIG_MANAGER_ROLE(), owner));
        assertFalse(hook.hasRole(hook.CONFIG_MANAGER_ROLE(), poolInitializer));
        assertFalse(hook.hasRole(hook.DEFAULT_ADMIN_ROLE(), configManager));
        assertFalse(hook.hasRole(hook.DEFAULT_ADMIN_ROLE(), poolInitializer));

        assertEq(address(uint160(uint256(vm.load(address(hook), ERC1967Utils.IMPLEMENTATION_SLOT)))), address(impl));
    }

    function test_hookAddress_hasExactlyFrozenFlagSet() public view {
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, HOOK_FLAGS);
    }

    // -------------------------------------------------------------------------
    // initialize
    // -------------------------------------------------------------------------

    function test_initialize_revertsForZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(BaseDynamicFeeHook.InvalidAdmin.selector, address(0)));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (address(0), poolInitializer, configManager))
        );
    }

    function test_initialize_revertsForSelfAdmin() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(BaseDynamicFeeHook.InvalidAdmin.selector, predicted));
        new ERC1967Proxy(
            address(impl), abi.encodeCall(BaseDynamicFeeHook.initialize, (predicted, poolInitializer, configManager))
        );
    }

    function test_initialize_revertsOnReinitialization() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hook.initialize(other, other, other);
    }

    // -------------------------------------------------------------------------
    // constructor
    // -------------------------------------------------------------------------

    function test_constructor_revertsForZeroMaxTempFeeBlockGap() public {
        vm.expectRevert(IVolatilePairHook.MaxTempFeeBlockGapCannotBeZero.selector);
        new VolatilePairHook(manager, 0);
    }

    /// The immutable lives in the implementation's code, so the proxy reads the implementation's value.
    function test_maxTempFeeBlockGap_readsImplementationValueThroughProxy() public view {
        assertEq(impl.maxTempFeeBlockGap(), MAX_TEMP_FEE_BLOCK_GAP);
        assertEq(hook.maxTempFeeBlockGap(), MAX_TEMP_FEE_BLOCK_GAP);
    }

    // -------------------------------------------------------------------------
    // Storage layout
    // -------------------------------------------------------------------------

    function test_storageLayout_documentedSlotMatchesPreimage() public pure {
        assertEq(
            FEE_CONFIGURATION_BASE_SLOT,
            keccak256(abi.encode(uint256(keccak256("uniswap.storage.VolatileFeeConfiguration")) - 1))
                & ~bytes32(uint256(0xff))
        );
    }

    function test_storageLayout_feeConfigAndFeeStateAtDocumentedSlots() public {
        vm.roll(1234);
        VolatileFeeConfig memory config = _distinctConfig();
        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, config);

        PoolId poolId = testPoolKey.toId();

        // feeState[poolId]: 40 + 160 + 24 + 24 + 8 = 256 bits
        uint256 rawState = uint256(vm.load(address(hook), _stateSlot(poolId)));
        assertEq(uint40(rawState), 0); // blockNumber: zeroed until the first swap
        assertEq(uint160(rawState >> 40), 0); // sqrtPriceTopX96
        assertEq(uint24(rawState >> 200), 500); // askPermFeeE6
        assertEq(uint24(rawState >> 224), 0); // tempFeeE6
        assertEq(uint8(rawState >> 248), 0); // tempOnBid

        // feeConfig[poolId]: the ten config fields in declaration order
        uint256 raw = uint256(vm.load(address(hook), _configSlot(poolId)));
        assertEq(uint24(raw), config.restingSpreadE6);
        assertEq(uint24(raw >> 24), config.backrunCaptureFractionE6);
        assertEq(uint24(raw >> 48), config.midFadeRateE6);
        assertEq(uint24(raw >> 72), config.maxMidFadeE6);
        assertEq(uint24(raw >> 96), config.skewRateE6);
        assertEq(uint24(raw >> 120), config.maxSkewStepE6);
        assertEq(uint24(raw >> 144), config.maxSkewE6);
        assertEq(uint24(raw >> 168), config.backrunThresholdE6);
        assertEq(uint24(raw >> 192), config.restoreFractionE6);
        assertEq(uint24(raw >> 216), config.restoreThresholdE6);
        assertEq(raw >> 240, 0);

        // each value is exactly one word
        assertEq(uint256(vm.load(address(hook), bytes32(uint256(_stateSlot(poolId)) + 1))), 0);
        assertEq(uint256(vm.load(address(hook), bytes32(uint256(_configSlot(poolId)) + 1))), 0);
    }

    // -------------------------------------------------------------------------
    // initializePool
    // -------------------------------------------------------------------------

    function test_initializePool_seedsConfigResetsStateAndInitializesPool() public {
        vm.roll(1234);
        VolatileFeeConfig memory config = _defaultConfig();

        vm.expectEmit(true, false, false, true, address(hook));
        emit IVolatileFeeConfiguration.FeeConfigUpdated(testPoolKey.toId(), config);
        vm.expectEmit(true, false, false, true, address(hook));
        emit IVolatilePairHook.PoolInitialized(testPoolKey, Constants.SQRT_PRICE_1_1, config);
        vm.prank(poolInitializer);
        int24 tick = hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, config);

        assertEq(tick, TickMath.getTickAtSqrtPrice(Constants.SQRT_PRICE_1_1));
        (uint160 slot0SqrtPriceX96, int24 slot0Tick,,) = manager.getSlot0(testPoolKey.toId());
        assertEq(slot0SqrtPriceX96, Constants.SQRT_PRICE_1_1);
        assertEq(slot0Tick, tick);

        assertEq(
            keccak256(abi.encode(_storedConfig(testPoolKey.toId()))),
            keccak256(abi.encode(config)),
            "config seeded verbatim"
        );

        VolatileFeeState memory state = _storedState(testPoolKey.toId());
        assertEq(state.blockNumber, 0, "zeroed until the first swap");
        assertEq(state.sqrtPriceTopX96, 0);
        assertEq(state.askPermFeeE6, RESTING_SPREAD_E6 / 2);
        assertEq(state.tempFeeE6, 0);
        assertFalse(state.tempOnBid);
        (uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) = _storedBaselines(testPoolKey.toId());
        assertEq(askBaselineFeeE6, RESTING_SPREAD_E6 / 2);
        assertEq(bidBaselineFeeE6, RESTING_SPREAD_E6 / 2);
    }

    function test_initializePool_revertsWithMustUseDynamicFee() public {
        PoolKey memory staticFeeKey = testPoolKey;
        staticFeeKey.fee = LPFeeLibrary.MAX_LP_FEE;

        vm.prank(poolInitializer);
        vm.expectRevert(abi.encodeWithSelector(IVolatilePairHook.MustUseDynamicFee.selector, LPFeeLibrary.MAX_LP_FEE));
        hook.initializePool(staticFeeKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    function test_initializePool_revertsWithInvalidHookAddress() public {
        PoolKey memory foreignHookKey = testPoolKey;
        foreignHookKey.hooks = IHooks(address(impl));

        vm.prank(poolInitializer);
        vm.expectRevert(abi.encodeWithSelector(IVolatilePairHook.InvalidHookAddress.selector, address(impl)));
        hook.initializePool(foreignHookKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    function test_initializePool_revertsWithRestingSpreadCannotBeZero() public {
        VolatileFeeConfig memory badConfig = _defaultConfig();
        badConfig.restingSpreadE6 = 0;

        vm.prank(poolInitializer);
        vm.expectRevert(abi.encodeWithSelector(IVolatileFeeConfiguration.RestingSpreadCannotBeZero.selector));
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, badConfig);
    }

    function test_initializePool_revertsForNonInitializer() public {
        bytes32 role = hook.POOL_INITIALIZER_ROLE();
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, role));
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    function test_initializePool_revertsForConfigManager() public {
        bytes32 role = hook.POOL_INITIALIZER_ROLE();
        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, configManager, role)
        );
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    // -------------------------------------------------------------------------
    // beforeInitialize
    // -------------------------------------------------------------------------

    /// v4 skips this callback when the hook itself calls `initialize`.
    function test_beforeInitialize_revertsForDirectPoolManagerInit() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BaseDynamicFeeHook.InvalidInitializer.selector, address(this)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(testPoolKey, Constants.SQRT_PRICE_1_1);
    }

    function test_beforeInitialize_revertsWhenNotPoolManager() public {
        vm.expectRevert(ImmutableState.NotPoolManager.selector);
        hook.beforeInitialize(address(hook), testPoolKey, Constants.SQRT_PRICE_1_1);
    }

    // -------------------------------------------------------------------------
    // Roles
    // -------------------------------------------------------------------------

    function test_rotatePoolInitializer_movesInitRightsImmediately() public {
        address nextInitializer = makeAddr("nextPoolInitializer");
        bytes32 role = hook.POOL_INITIALIZER_ROLE();

        vm.startPrank(owner);
        hook.grantRole(role, nextInitializer);
        hook.revokeRole(role, poolInitializer);
        vm.stopPrank();

        vm.prank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, role)
        );
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());

        vm.prank(nextInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
        (uint160 slot0SqrtPriceX96,,,) = manager.getSlot0(testPoolKey.toId());
        assertEq(slot0SqrtPriceX96, Constants.SQRT_PRICE_1_1);
    }

    function test_renounceRole_disablesFurtherWrites() public {
        _initializeTestPool();
        bytes32 configManagerRole = hook.CONFIG_MANAGER_ROLE();
        bytes32 poolInitializerRole = hook.POOL_INITIALIZER_ROLE();

        vm.prank(configManager);
        hook.renounceRole(configManagerRole, configManager);
        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, configManager, configManagerRole
            )
        );
        hook.updateFeeConfig(testPoolKey.toId(), _distinctConfig());

        vm.prank(poolInitializer);
        hook.renounceRole(poolInitializerRole, poolInitializer);
        vm.prank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, poolInitializerRole
            )
        );
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    function test_operationalRoles_cannotGrantOrRevokeRoles() public {
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();
        bytes32 configManagerRole = hook.CONFIG_MANAGER_ROLE();
        bytes32 poolInitializerRole = hook.POOL_INITIALIZER_ROLE();

        vm.startPrank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, configManager, adminRole)
        );
        hook.grantRole(configManagerRole, other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, configManager, adminRole)
        );
        hook.revokeRole(poolInitializerRole, poolInitializer);
        vm.stopPrank();

        vm.startPrank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, adminRole)
        );
        hook.grantRole(poolInitializerRole, other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, adminRole)
        );
        hook.revokeRole(configManagerRole, configManager);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------------
    // Getters
    // -------------------------------------------------------------------------

    function test_feeConfigAndFeeState_readBackEveryStoredField() public {
        _initializeTestPool();
        VolatileFeeConfig memory config = _distinctConfig();
        _setConfig(config);

        PoolId poolId = testPoolKey.toId();
        VolatileFeeConfig memory stored = _storedConfig(poolId);
        assertEq(stored.restingSpreadE6, config.restingSpreadE6);
        assertEq(stored.backrunCaptureFractionE6, config.backrunCaptureFractionE6);
        assertEq(stored.midFadeRateE6, config.midFadeRateE6);
        assertEq(stored.maxMidFadeE6, config.maxMidFadeE6);
        assertEq(stored.skewRateE6, config.skewRateE6);
        assertEq(stored.maxSkewStepE6, config.maxSkewStepE6);
        assertEq(stored.maxSkewE6, config.maxSkewE6);
        assertEq(stored.backrunThresholdE6, config.backrunThresholdE6);
        assertEq(stored.restoreFractionE6, config.restoreFractionE6);
        assertEq(stored.restoreThresholdE6, config.restoreThresholdE6);

        VolatileFeeState memory state = _storedState(poolId);
        assertEq(state.blockNumber, 0, "zeroed until the first swap");
        assertEq(state.sqrtPriceTopX96, 0);
        assertEq(state.askPermFeeE6, 500);
        assertEq(state.tempFeeE6, 0);
        assertFalse(state.tempOnBid);
        (uint24 askBaselineFeeE6, uint24 bidBaselineFeeE6) = _storedBaselines(poolId);
        assertEq(askBaselineFeeE6, 500);
        assertEq(bidBaselineFeeE6, 501);
    }

    function test_feeConfigAndFeeState_zeroForUntouchedPool() public {
        _initializeTestPool(); // a neighbour's config must not leak

        PoolId untouched = unusedPoolKey.toId();
        assertEq(
            keccak256(abi.encode(_storedConfig(untouched))),
            keccak256(abi.encode(VolatileFeeConfig(0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        );
        VolatileFeeState memory zeroState;
        assertEq(keccak256(abi.encode(_storedState(untouched))), keccak256(abi.encode(zeroState)));

        vm.prank(configManager);
        vm.expectRevert(abi.encodeWithSelector(IDynamicFeeHook.PoolNotInitialized.selector, untouched));
        hook.updateFeeConfig(untouched, _defaultConfig());
    }

    // -------------------------------------------------------------------------
    // Gas
    // -------------------------------------------------------------------------

    function test_initializePool_gas() public {
        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
        vm.snapshotGasLastCall("initializePool");
    }

    function test_poolCreationHookless_gas() public {
        manager.initialize(unusedPoolKey, Constants.SQRT_PRICE_1_1);
        vm.snapshotGasLastCall("poolCreationHookless");
    }
}
