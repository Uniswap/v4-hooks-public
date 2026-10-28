// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VolatilePairTestBase} from "./base/VolatilePairTestBase.sol";
import {VolatilePairHook} from "../../src/volatile/VolatilePairHook.sol";
import {BaseDynamicFeeHook} from "../../src/base/BaseDynamicFeeHook.sol";
import {BaseUUPSHook} from "../../src/base/BaseUUPSHook.sol";
import {VolatileFeeConfig, VolatileFeeState} from "../../src/volatile/interfaces/IVolatileFeeConfiguration.sol";
import {VolatilePairHookV2Mock} from "../mocks/VolatilePairHookV2Mock.sol";
import {VolatileDifferentFlagsMock} from "../mocks/VolatileDifferentFlagsMock.sol";
import {NotUUPSHookMock} from "../mocks/NotUUPSHookMock.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
// Imported only so forge builds the artifact `deployCodeTo` loads by name.
import {ERC1967Proxy as _ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/// UUPS mechanics of BaseUUPSHook / BaseDynamicFeeHook through VolatilePairHook.
contract VolatilePairHookUpgradeTest is VolatilePairTestBase, Deployers {
    using PoolIdLibrary for PoolKey;

    event Upgraded(address indexed implementation); // ERC1967

    VolatilePairHook internal impl;
    address internal other = makeAddr("other");

    function setUp() public override {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

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
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });

        vm.prank(poolInitializer);
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    function _upgradeToV2() internal returns (VolatilePairHookV2Mock v2) {
        VolatilePairHookV2Mock v2Impl = new VolatilePairHookV2Mock(manager, MAX_TEMP_FEE_BLOCK_GAP);
        vm.prank(owner);
        hook.upgradeToAndCall(address(v2Impl), "");
        v2 = VolatilePairHookV2Mock(address(hook));
    }

    function _addLiquidity(PoolKey memory key) internal {
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: 100e18, salt: 0}), ZERO_BYTES
        );
    }

    // -------------------------------------------------------------------------
    // Authorization
    // -------------------------------------------------------------------------

    function test_upgrade_revertsForNonAdmin() public {
        VolatilePairHookV2Mock v2Impl = new VolatilePairHookV2Mock(manager, MAX_TEMP_FEE_BLOCK_GAP);
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgrade_revertsForConfigManagerAndPoolInitializer() public {
        VolatilePairHookV2Mock v2Impl = new VolatilePairHookV2Mock(manager, MAX_TEMP_FEE_BLOCK_GAP);
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();

        vm.prank(configManager);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, configManager, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");

        vm.prank(poolInitializer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, poolInitializer, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");
    }

    // -------------------------------------------------------------------------
    // Implementation validation
    // -------------------------------------------------------------------------

    /// Empty revert: the `poolManager()` staticcall fails before OZ's UUID check.
    function test_upgrade_revertsForNonUUPSImplementation() public {
        NotUUPSHookMock notUUPS = new NotUUPSHookMock();
        vm.prank(owner);
        vm.expectRevert(bytes(""));
        hook.upgradeToAndCall(address(notUUPS), "");
    }

    /// Empty revert: the ABI decoder fails on empty returndata before OZ's code-length check.
    function test_upgrade_revertsForTargetWithoutCode() public {
        vm.prank(owner);
        vm.expectRevert(bytes(""));
        hook.upgradeToAndCall(other, "");

        vm.prank(owner);
        vm.expectRevert(bytes(""));
        hook.upgradeToAndCall(address(0), "");
    }

    function test_upgrade_revertsForWrongPoolManager() public {
        PoolManager otherManager = new PoolManager(address(this));
        VolatilePairHookV2Mock badImpl = new VolatilePairHookV2Mock(otherManager, MAX_TEMP_FEE_BLOCK_GAP);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(BaseUUPSHook.InvalidPoolManager.selector, address(otherManager)));
        hook.upgradeToAndCall(address(badImpl), "");
    }

    /// The proxy address encodes the flag set, freezing it for every future implementation.
    function test_upgrade_revertsForDifferentHookPermissions() public {
        VolatileDifferentFlagsMock badImpl = new VolatileDifferentFlagsMock(manager);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, address(hook)));
        hook.upgradeToAndCall(address(badImpl), "");
    }

    // -------------------------------------------------------------------------
    // State preservation
    // -------------------------------------------------------------------------

    function test_upgrade_preservesRolesAndStorage() public {
        _addLiquidity(testPoolKey);
        swap(testPoolKey, true, -1e18, ZERO_BYTES);

        PoolId poolId = testPoolKey.toId();
        VolatileFeeConfig memory configBefore = _storedConfig(poolId);
        VolatileFeeState memory stateBefore = _storedState(poolId);
        assertGt(stateBefore.sqrtPriceTopX96, 0, "the swap must have cached a block-open price");

        bytes32 rawStateBefore = _rawStateHash(poolId);

        VolatilePairHookV2Mock v2 = _upgradeToV2();

        assertEq(v2.version(), 2, "new logic must be active");
        assertTrue(v2.hasRole(v2.DEFAULT_ADMIN_ROLE(), owner));
        assertTrue(v2.hasRole(v2.POOL_INITIALIZER_ROLE(), poolInitializer));
        assertTrue(v2.hasRole(v2.CONFIG_MANAGER_ROLE(), configManager));

        assertEq(keccak256(abi.encode(_storedConfig(poolId))), keccak256(abi.encode(configBefore)), "config getter");
        assertEq(keccak256(abi.encode(_storedState(poolId))), keccak256(abi.encode(stateBefore)), "state getter");

        assertEq(_rawStateHash(poolId), rawStateBefore, "hook state slots");
    }

    function test_upgrade_preservesPricing() public {
        _addLiquidity(testPoolKey);
        swap(testPoolKey, true, -1e18, ZERO_BYTES);
        vm.roll(block.number + 1);
        swap(testPoolKey, true, -1e18, ZERO_BYTES);
        assertTrue(
            _storedState(testPoolKey.toId()).askPermFeeE6 != RESTING_SPREAD_E6 / 2,
            "skew must have left its neutral split"
        );

        // fresh block, no swap: both quotes derive purely from stored state
        vm.roll(block.number + 1);
        (uint24 zeroForOneBeforeE6, uint24 oneForZeroBeforeE6) = hook.getFee(testPoolKey);
        assertTrue(zeroForOneBeforeE6 != oneForZeroBeforeE6, "the two sides must be priced apart");

        _upgradeToV2();

        (uint24 zeroForOneAfterE6, uint24 oneForZeroAfterE6) = hook.getFee(testPoolKey);
        assertEq(zeroForOneAfterE6, zeroForOneBeforeE6, "same fee on the bid side");
        assertEq(oneForZeroAfterE6, oneForZeroBeforeE6, "same fee on the ask side");
    }

    // -------------------------------------------------------------------------
    // Post-upgrade liveness
    // -------------------------------------------------------------------------

    function test_upgrade_allEnabledHookPathsStillWork() public {
        _upgradeToV2();

        PoolKey memory freshKey = testPoolKey;
        freshKey.tickSpacing = TICK_SPACING * 2;
        vm.prank(poolInitializer);
        hook.initializePool(freshKey, Constants.SQRT_PRICE_1_1, _defaultConfig());

        _addLiquidity(freshKey);

        BalanceDelta delta = swap(freshKey, true, -1e15, ZERO_BYTES);
        assertGt(delta.amount1(), 0);

        modifyLiquidityRouter.modifyLiquidity(
            freshKey,
            ModifyLiquidityParams({tickLower: -6000, tickUpper: 6000, liquidityDelta: -100e18, salt: 0}),
            ZERO_BYTES
        );
    }

    function test_upgrade_accessControlStillEnforced() public {
        _upgradeToV2();

        bytes32 configManagerRole = hook.CONFIG_MANAGER_ROLE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, configManagerRole)
        );
        hook.updateFeeConfig(testPoolKey.toId(), _defaultConfig());

        bytes32 poolInitializerRole = hook.POOL_INITIALIZER_ROLE();
        vm.prank(other);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, other, poolInitializerRole)
        );
        hook.initializePool(testPoolKey, Constants.SQRT_PRICE_1_1, _defaultConfig());
    }

    // -------------------------------------------------------------------------
    // Initialization safety
    // -------------------------------------------------------------------------

    function test_initialize_revertsAfterUpgradeAndOnBareImplementation() public {
        _upgradeToV2();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        hook.initialize(other, other, other);

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(other, other, other);
    }

    function test_upgradeToAndCall_revertsOnBareImplementation() public {
        VolatilePairHook newImpl = new VolatilePairHook(manager, MAX_TEMP_FEE_BLOCK_GAP);
        vm.expectRevert(UUPSUpgradeable.UUPSUnauthorizedCallContext.selector);
        impl.upgradeToAndCall(address(newImpl), "");
    }

    // -------------------------------------------------------------------------
    // Admin transfer
    // -------------------------------------------------------------------------

    function test_adminHandover_movesUpgradeRights() public {
        address newAdmin = makeAddr("newAdmin");
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();

        vm.startPrank(owner);
        hook.grantRole(adminRole, newAdmin);
        hook.revokeRole(adminRole, owner);
        vm.stopPrank();

        VolatilePairHookV2Mock v2Impl = new VolatilePairHookV2Mock(manager, MAX_TEMP_FEE_BLOCK_GAP);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");

        vm.prank(newAdmin);
        hook.upgradeToAndCall(address(v2Impl), "");
        assertEq(VolatilePairHookV2Mock(address(hook)).version(), 2);
    }

    function test_renounceAdmin_freezesUpgrades() public {
        bytes32 adminRole = hook.DEFAULT_ADMIN_ROLE();
        vm.prank(owner);
        hook.renounceRole(adminRole, owner);

        VolatilePairHookV2Mock v2Impl = new VolatilePairHookV2Mock(manager, MAX_TEMP_FEE_BLOCK_GAP);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, adminRole)
        );
        hook.upgradeToAndCall(address(v2Impl), "");

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, owner, adminRole)
        );
        hook.grantRole(adminRole, owner);
    }

    // -------------------------------------------------------------------------
    // Upgrade mechanics
    // -------------------------------------------------------------------------

    function test_upgrade_emitsUpgraded() public {
        VolatilePairHookV2Mock v2Impl = new VolatilePairHookV2Mock(manager, MAX_TEMP_FEE_BLOCK_GAP);
        vm.expectEmit(true, false, false, false, address(hook));
        emit Upgraded(address(v2Impl));
        vm.prank(owner);
        hook.upgradeToAndCall(address(v2Impl), "");
    }

    function test_upgradeToAndCall_initializesV2State() public {
        VolatileFeeConfig memory configBefore = _storedConfig(testPoolKey.toId());

        VolatilePairHookV2Mock v2Impl = new VolatilePairHookV2Mock(manager, MAX_TEMP_FEE_BLOCK_GAP);
        vm.prank(owner);
        hook.upgradeToAndCall(address(v2Impl), abi.encodeCall(VolatilePairHookV2Mock.initializeV2, (42)));

        VolatilePairHookV2Mock v2 = VolatilePairHookV2Mock(address(hook));
        assertEq(v2.newValue(), 42);
        assertEq(v2.version(), 2);
        assertEq(
            keccak256(abi.encode(_storedConfig(testPoolKey.toId()))),
            keccak256(abi.encode(configBefore)),
            "V1's namespace must be undisturbed"
        );

        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initializeV2(43);
    }

    function test_upgrade_gas() public {
        VolatilePairHookV2Mock v2Impl = new VolatilePairHookV2Mock(manager, MAX_TEMP_FEE_BLOCK_GAP);
        vm.prank(owner);
        hook.upgradeToAndCall(address(v2Impl), "");
        vm.snapshotGasLastCall("upgradeToAndCall");
    }
}
