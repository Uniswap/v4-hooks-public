// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PropAMMIndex} from "../../src/propamm/PropAMMIndex.sol";
import {AttestationRegistry} from "../../src/propamm/AttestationRegistry.sol";
import {IPropAMMIndex, QuoterType} from "../../src/propamm/interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry, Attestation} from "../../src/propamm/interfaces/IAttestationRegistry.sol";
import {MockQuoterHook} from "./mocks/MockQuoterHook.sol";
import {MockAttestationSigner} from "./mocks/MockAttestationSigner.sol";
import {QuoterHookData} from "../../src/propamm/interfaces/IQuoterHook.sol";

contract BasePropAMMHookTest is Test, Deployers {
    PropAMMIndex public index;
    AttestationRegistry public attestationRegistry;
    MockQuoterHook public hook;

    address owner = makeAddr("owner");
    uint256 attesterPk;
    address attester;

    Currency tokenA;
    Currency tokenB;
    PoolKey testPoolKey;

    function setUp() public {
        deployFreshManagerAndRouters();

        index = new PropAMMIndex();
        attestationRegistry = new AttestationRegistry(owner);

        (attester, attesterPk) = makeAddrAndKey("attester");
        vm.prank(owner);
        attestationRegistry.addAttester(attester);

        // Deploy MockQuoterHook at a flag-mined address
        uint160 flags =
            uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG);
        hook = MockQuoterHook(address(uint160(uint256(type(uint160).max) & clearAllHookPermissionsMask | flags)));
        deployCodeTo(
            "MockQuoterHook",
            abi.encode(manager, address(index), address(attestationRegistry), uint32(50_000)),
            address(hook)
        );

        tokenA = Currency.wrap(address(0xA));
        tokenB = Currency.wrap(address(0xB));
        testPoolKey =
            PoolKey({currency0: tokenA, currency1: tokenB, fee: 3000, tickSpacing: 60, hooks: IHooks(address(hook))});

        // Set default prices
        hook.setPrice(1000e18, 1001e18);
    }

    // ──── maxGas ────

    function test_maxGas_returnsConstructorValue() public view {
        assertEq(hook.maxGas(), 50_000);
    }

    // ──── getIndicativeQuote ────

    function test_getIndicativeQuote_unattested() public view {
        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -1e18, "");
        assertEq(output, 1000e18);
    }

    function test_getIndicativeQuote_attested() public {
        Attestation memory att = Attestation({
            attester: attester,
            swapper: makeAddr("swapper"),
            deadline: block.timestamp + 1 hours,
            swapHash: keccak256(abi.encode("test"))
        });
        bytes memory attestationData = MockAttestationSigner.sign(vm, attesterPk, att, address(attestationRegistry));
        bytes memory hookData = abi.encode(QuoterHookData({attestationData: attestationData, curveUpdateData: ""}));

        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -1e18, hookData);
        assertEq(output, 1001e18);
    }

    function test_getIndicativeQuote_invalidAttestationFallsBackToUnattested() public view {
        // Bad attestation data wrapped in valid QuoterHookData struct
        bytes memory hookData = abi.encode(QuoterHookData({attestationData: hex"deadbeef0000", curveUpdateData: ""}));

        uint256 output = hook.getIndicativeQuote(testPoolKey, true, -1e18, hookData);
        assertEq(output, 1000e18);
    }

    // ──── isLive ────

    function test_isLive() public view {
        assertTrue(hook.isLive());
    }

    function test_isLive_afterSetFalse() public {
        hook.setLive(false);
        assertFalse(hook.isLive());
    }

    // ──── Index helpers ────

    function test_registerInIndex() public {
        hook.registerInIndex(testPoolKey, QuoterType.STORAGE, "");
        assertTrue(index.isRegistered(address(hook), testPoolKey));
    }

    function test_setLiveInIndex() public {
        hook.registerInIndex(testPoolKey, QuoterType.STORAGE, "");

        hook.setLiveInIndex(testPoolKey, false);
        assertFalse(index.getQuoter(address(hook), testPoolKey).isLive);
    }

    function test_deregisterFromIndex() public {
        hook.registerInIndex(testPoolKey, QuoterType.STORAGE, "");

        hook.deregisterFromIndex(testPoolKey);
        assertFalse(index.isRegistered(address(hook), testPoolKey));
    }
}
