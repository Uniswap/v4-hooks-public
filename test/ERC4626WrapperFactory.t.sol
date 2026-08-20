// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {HookMiner} from "../src/utils/HookMiner.sol";
import {AllowlistedFactory} from "../src/AllowlistedFactory.sol";
import {IAllowlistedFactory} from "../src/interfaces/IAllowlistedFactory.sol";
import {ERC4626WrapperHook} from "../src/ERC4626WrapperHook.sol";
import {ERC4626RoutingHook} from "../src/ERC4626RoutingHook.sol";
import {MockRebasingERC20} from "./mocks/MockRebasingERC20.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {TestRouter} from "./shared/TestRouter.sol";

/// @title ERC4626WrapperFactoryTest
/// @notice Tests for the ERC-4626 wrapper hook family's `AllowlistedFactory` deployment model:
///         hash-pinned CREATE2 deployment of `ERC4626WrapperHook` and `ERC4626RoutingHook`,
///         registration and discovery views, the hooks' `factory()` provenance getter, and
///         end-to-end operability of a factory-deployed hook. Factory-generic failure paths
///         (foreign bytecode, salt reuse, allowlist validation) are covered in
///         `test/alf/AllowlistedFactory.t.sol`.
contract ERC4626WrapperFactoryTest is Test, Deployers {
    using SafeCast for uint256;

    uint160 constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    AllowlistedFactory factory;
    MockRebasingERC20 underlying;
    MockERC4626Vault vault;
    TestRouter router;

    bytes32 wrapperHash;
    bytes32 routingHash;

    address alice = makeAddr("alice");

    function setUp() public {
        deployFreshManagerAndRouters();
        router = new TestRouter(manager);

        underlying = new MockRebasingERC20("Mock xStock", "AAPLx", 18);
        vault = new MockERC4626Vault(address(underlying), "Wrapped Mock xStock", "wAAPLx", 18);

        // Seed the vault with backing so totalSupply > 0 and shares are fully backed
        uint256 seed = 1_000_000 ether;
        underlying.mint(address(this), seed);
        underlying.approve(address(vault), type(uint256).max);
        vault.deposit(seed, address(this));

        wrapperHash = keccak256(type(ERC4626WrapperHook).creationCode);
        routingHash = keccak256(type(ERC4626RoutingHook).creationCode);

        bytes32[] memory allowed = new bytes32[](2);
        allowed[0] = wrapperHash;
        allowed[1] = routingHash;
        factory = new AllowlistedFactory(allowed);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              HELPERS
    // ═══════════════════════════════════════════════════════════════════════════

    function _args() internal view returns (bytes memory) {
        return abi.encode(manager, IERC4626(address(vault)));
    }

    /// @dev Mine a flags-valid salt against the factory as CREATE2 deployer and deploy through it.
    function _mineAndDeploy(bytes memory creationCode) internal returns (address expected, bytes32 salt, address hook) {
        (expected, salt) = HookMiner.find(address(factory), FLAGS, creationCode, _args());
        hook = factory.deploy(creationCode, _args(), salt);
    }

    function _poolKey(address hook) internal view returns (PoolKey memory) {
        (address a, address b) = (address(underlying), address(vault));
        (Currency currency0, Currency currency1) =
            a < b ? (Currency.wrap(a), Currency.wrap(b)) : (Currency.wrap(b), Currency.wrap(a));
        return PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              DEPLOYMENT
    // ═══════════════════════════════════════════════════════════════════════════

    function test_constructor_setsAllowlist() public view {
        assertTrue(factory.isAllowedCreationCode(wrapperHash));
        assertTrue(factory.isAllowedCreationCode(routingHash));
        assertEq(factory.allDeploymentsLength(), 0);
    }

    function test_deploy_deploysAtMinedAddress_withValidFlags() public {
        (address expected, bytes32 salt, address hook) = _mineAndDeploy(type(ERC4626WrapperHook).creationCode);

        assertEq(hook, expected);
        assertEq(hook, factory.computeAddress(type(ERC4626WrapperHook).creationCode, _args(), salt));
        assertEq(uint160(hook) & HookMiner.FLAG_MASK, FLAGS);
        assertGt(hook.code.length, 0);
    }

    function test_deploy_registersHook() public {
        (,, address hook) = _mineAndDeploy(type(ERC4626WrapperHook).creationCode);

        assertTrue(factory.isFromFactory(hook));
        assertEq(factory.creationCodeHashOf(hook), wrapperHash);
        assertEq(factory.allDeploymentsLength(), 1);
        assertEq(factory.allDeployments(0), hook);
    }

    function test_deploy_emitsDeployed() public {
        bytes memory creationCode = type(ERC4626WrapperHook).creationCode;
        (address expected, bytes32 salt) = HookMiner.find(address(factory), FLAGS, creationCode, _args());

        vm.expectEmit(true, true, true, true, address(factory));
        emit IAllowlistedFactory.Deployed(expected, wrapperHash, address(this), _args(), salt);
        factory.deploy(creationCode, _args(), salt);
    }

    function test_deploy_hookReportsFactoryAndConfig() public {
        (,, address hookAddr) = _mineAndDeploy(type(ERC4626WrapperHook).creationCode);
        ERC4626WrapperHook hook = ERC4626WrapperHook(hookAddr);

        assertEq(hook.factory(), address(factory));
        assertEq(address(hook.vault()), address(vault));
        assertEq(Currency.unwrap(hook.wrapperCurrency()), address(vault));
        assertEq(Currency.unwrap(hook.underlyingCurrency()), address(underlying));
        assertEq(hook.wrapZeroForOne(), address(underlying) < address(vault));
    }

    /// @dev The routing hook (the wrapper hook's quoting counterpart) deploys through the same
    ///      factory and registers under its OWN creation-code hash, so integrators can tell the
    ///      pool hook from the quoter by keying on the hash in the `Deployed` event / registry.
    function test_deploy_routingHook_registersWithOwnHash() public {
        (,, address hookAddr) = _mineAndDeploy(type(ERC4626WrapperHook).creationCode);
        (,, address routingAddr) = _mineAndDeploy(type(ERC4626RoutingHook).creationCode);

        assertEq(factory.creationCodeHashOf(hookAddr), wrapperHash);
        assertEq(factory.creationCodeHashOf(routingAddr), routingHash);
        assertTrue(factory.isFromFactory(routingAddr));
        assertEq(ERC4626RoutingHook(routingAddr).factory(), address(factory));
        assertEq(factory.allDeploymentsLength(), 2);
        assertEq(factory.allDeployments(0), hookAddr);
        assertEq(factory.allDeployments(1), routingAddr);
    }

    /// @dev End-to-end sanity: a factory-deployed hook is fully operational against the
    ///      PoolManager (its pool initializes and a wrap swap mints shares at the vault rate).
    function test_deploy_deployedHookWrapsViaSwap() public {
        (,, address hookAddr) = _mineAndDeploy(type(ERC4626WrapperHook).creationCode);
        PoolKey memory key = _poolKey(hookAddr);
        manager.initialize(key, SQRT_PRICE_1_1);

        uint256 amount = 1 ether;
        underlying.mint(alice, amount);
        vm.startPrank(alice);
        underlying.approve(address(router), type(uint256).max);

        bool wrapZeroForOne = address(underlying) < address(vault);
        uint256 expectedShares = vault.previewDeposit(amount);
        router.swap(
            key,
            SwapParams({
                zeroForOne: wrapZeroForOne,
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: wrapZeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            ""
        );
        vm.stopPrank();

        assertEq(underlying.balanceOf(alice), 0);
        assertEq(vault.balanceOf(alice), expectedShares);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //                              PROVENANCE SEMANTICS
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev `factory()` reports the constructor-time `msg.sender`, whoever that is: a hook
    ///      deployed outside the factory reports its direct deployer and is NOT registered.
    ///      Aggregators must therefore check provenance against the known factory address.
    function test_factory_reportsDirectDeployer_forNonFactoryDeploys() public {
        address hookAddr = address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | FLAGS));
        deployCodeTo("ERC4626WrapperHook", _args(), hookAddr);

        assertEq(ERC4626WrapperHook(hookAddr).factory(), address(this));
        assertFalse(factory.isFromFactory(hookAddr));
    }
}
