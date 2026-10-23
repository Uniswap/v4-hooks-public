// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {QuoterRevert} from "@uniswap/v4-periphery/src/libraries/QuoterRevert.sol";
import {
    IPermissionsAdapter
} from "@uniswap/v4-periphery/src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol";
import {PermissionFlags} from "@uniswap/v4-periphery/src/hooks/permissionedPools/libraries/PermissionFlags.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Proves that a quoter is only usable against a permissioned pool when it implements
/// `msgSender()` AND the adapters allowlist it as a wrapper AND the swapper is allowlisted.
/// A quoter without `msgSender()` also reverts, so "it reverts" alone proves nothing; every
/// failing row asserts the exact inner reason the hook bubbled up.
///
/// Sepolia fork, pinned. Nothing is broadcast; adapter mutations are pranked from the owner.
/// Swap the quoter (and pool) through env to reuse for MixedRouteQuoterV2 or a future redeploy:
///   QUOTER_FRESH, QUOTER_STALE, FORK_BLOCK
contract QuoterPermissionMatrixForkTest is Test {
    // Mock-env pool PA2/PA1 on the Sepolia PermissionedHooks deployment.
    address constant PA2 = 0x8308119359F9fb7Dea90b1B977276A6d89902818; // currency0, mapping checker
    address constant PA1 = 0xc6F4B10E842D16a35Dd49853A9D3f3169442BFd0; // currency1, approve-all checker
    address constant HOOK = 0x51247E2291d290d17C08813A175AC86465EdE8c0;
    address constant OWNER = 0x2179a60856E37dfeAacA0ab043B931fE224b27B6; // owns PA1 and PA2
    // Selectors the hook bubbles up as the inner reason (keccak of the error signatures).
    bytes4 constant UNAUTHORIZED = bytes4(keccak256("Unauthorized()")); // 0x82b42900
    bytes4 constant SWAPPING_DISABLED = bytes4(keccak256("SwappingDisabled()")); // 0x888f3785
    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;

    address quoterFresh;
    address quoterStale;
    PoolKey key;

    function setUp() public {
        quoterFresh = vm.envOr("QUOTER_FRESH", 0x68aFa8b853cAa7a2D40B0F6AEE5C4DbC147C8244);
        quoterStale = vm.envOr("QUOTER_STALE", 0x61B3f2011A92d183C7dbaDBdA940a7555Ccf9227);
        // Pinned block needs an archive node; SEPOLIA_RPC_URL overrides the foundry.toml alias.
        vm.createSelectFork(vm.envOr("SEPOLIA_RPC_URL", string("sepolia")), vm.envOr("FORK_BLOCK", uint256(11_923_164)));
        key = PoolKey({
            currency0: Currency.wrap(PA2),
            currency1: Currency.wrap(PA1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
    }

    function _params() internal view returns (IV4Quoter.QuoteExactSingleParams memory) {
        return IV4Quoter.QuoteExactSingleParams({poolKey: key, zeroForOne: true, exactAmount: 1e12, hookData: ""});
    }

    /// @dev `vm.prank(from)` makes the quoter's Locker record `from`, exactly like `cast call --from`.
    function _quote(address quoter, address from) internal returns (bool ok, uint256 amountOut, bytes memory err) {
        vm.prank(from);
        try IV4Quoter(quoter).quoteExactInputSingle(_params()) returns (uint256 a, uint256) {
            return (true, a, "");
        } catch (bytes memory r) {
            return (false, 0, r);
        }
    }

    function strip(bytes calldata b) external pure returns (bytes calldata) {
        return b[4:];
    }

    /// @dev Unwraps UnexpectedRevertBytes(WrappedError(hook, beforeSwap, reason, HookCallFailed)) and returns `reason`.
    function _inner(bytes memory r) internal view returns (bytes memory reason) {
        assertEq(bytes4(r), QuoterRevert.UnexpectedRevertBytes.selector, "outer: UnexpectedRevertBytes");
        bytes memory wrapped = abi.decode(this.strip(r), (bytes));
        assertEq(bytes4(wrapped), CustomRevert.WrappedError.selector, "middle: WrappedError");
        (address target, bytes4 selector, bytes memory rsn, bytes memory details) =
            abi.decode(this.strip(wrapped), (address, bytes4, bytes, bytes));
        assertEq(target, HOOK, "wrapped target is the hook");
        assertEq(selector, IHooks.beforeSwap.selector, "wrapped selector is beforeSwap");
        assertEq(bytes4(details), Hooks.HookCallFailed.selector, "details: HookCallFailed");
        return rsn;
    }

    function _allowFreshOnBothAdapters() internal {
        vm.startPrank(OWNER);
        IPermissionsAdapter(PA1).updateAllowedWrapper(quoterFresh, true);
        IPermissionsAdapter(PA2).updateAllowedWrapper(quoterFresh, true);
        vm.stopPrank();
    }

    function test_staleQuoter_revertsWithEmptyReason() public {
        (bool ok,, bytes memory err) = _quote(quoterStale, OWNER);
        assertFalse(ok);
        assertEq(_inner(err).length, 0, "stale quoter has no msgSender(): empty inner reason");
    }

    function test_freshQuoter_notAllowedWrapper_revertsUnauthorized() public {
        assertFalse(IPermissionsAdapter(PA1).allowedWrappers(quoterFresh));
        assertFalse(IPermissionsAdapter(PA2).allowedWrappers(quoterFresh));
        (bool ok,, bytes memory err) = _quote(quoterFresh, OWNER);
        assertFalse(ok);
        assertEq(bytes4(_inner(err)), UNAUTHORIZED, "Unauthorized()");
    }

    function test_freshQuoter_allowed_strangerSwapper_revertsUnauthorized() public {
        _allowFreshOnBothAdapters();
        address stranger = makeAddr("stranger");
        assertFalse(IPermissionsAdapter(PA2).isAllowed(stranger, PermissionFlags.SWAP_ALLOWED));
        (bool ok,, bytes memory err) = _quote(quoterFresh, stranger);
        assertFalse(ok);
        assertEq(bytes4(_inner(err)), UNAUTHORIZED, "Unauthorized()");
    }

    function test_freshQuoter_allowed_allowlistedSwapper_quotes() public {
        _allowFreshOnBothAdapters();
        assertTrue(IPermissionsAdapter(PA2).isAllowed(OWNER, PermissionFlags.SWAP_ALLOWED));
        (bool ok, uint256 amountOut, bytes memory err) = _quote(quoterFresh, OWNER);
        assertTrue(ok, string(abi.encodePacked("quote failed: ", vm.toString(err))));
        assertGt(amountOut, 0);
    }

    function test_freshQuoter_allowed_swappingDisabled_revertsSwappingDisabled() public {
        _allowFreshOnBothAdapters();
        vm.prank(OWNER);
        IPermissionsAdapter(PA2).updateSwappingEnabled(false);
        (bool ok,, bytes memory err) = _quote(quoterFresh, OWNER);
        assertFalse(ok);
        assertEq(bytes4(_inner(err)), SWAPPING_DISABLED, "SwappingDisabled()");
    }
}
