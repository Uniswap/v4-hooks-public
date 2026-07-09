// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {ERC4626WrapperHook} from "../src/ERC4626WrapperHook.sol";
import {MockRebasingERC20} from "./mocks/MockRebasingERC20.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {TestRouter} from "./shared/TestRouter.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @title ERC4626 Wrapper Hook Handler
/// @notice Drives random wrap/unwrap swaps (across a set of actors) and rebases for the invariant
/// @dev campaign. Inputs are bounded to valid ranges and ghost counters track executed actions.
contract ERC4626WrapperHandler is Test {
    TestRouter public immutable router;
    MockRebasingERC20 public immutable underlying;
    MockERC4626Vault public immutable vault;
    PoolKey internal key;
    bool internal immutable wrapZeroForOne;

    uint256 internal constant MIN_AMOUNT = 1e12;

    address[] public actors;
    address internal currentActor;

    // Ghost accounting
    uint256 public ghost_wraps;
    uint256 public ghost_unwraps;
    uint256 public ghost_rebases;
    uint256 public ghost_skips;

    modifier useActor(uint256 actorSeed) {
        currentActor = actors[bound(actorSeed, 0, actors.length - 1)];
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    constructor(
        TestRouter _router,
        MockRebasingERC20 _underlying,
        MockERC4626Vault _vault,
        PoolKey memory _key,
        bool _wrapZeroForOne
    ) {
        router = _router;
        underlying = _underlying;
        vault = _vault;
        key = _key;
        wrapZeroForOne = _wrapZeroForOne;

        // Source shares to distribute by depositing underlying into the vault
        underlying.mint(address(this), 10_000_000 ether);
        underlying.approve(address(_vault), type(uint256).max);
        uint256 shares = _vault.deposit(4_000_000 ether, address(this));

        // Create and fund a small set of actors
        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string(abi.encodePacked("actor", i)));
            actors.push(actor);
            underlying.mint(actor, 1_000_000 ether);
            vault.transfer(actor, shares / 8);
            vm.startPrank(actor);
            underlying.approve(address(router), type(uint256).max);
            vault.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @notice Wrap a bounded amount of underlying into shares as a random actor
    function wrap(uint256 amount, uint256 actorSeed) external useActor(actorSeed) {
        uint256 balance = underlying.balanceOf(currentActor);
        if (balance < MIN_AMOUNT) {
            ghost_skips++;
            return;
        }
        amount = bound(amount, MIN_AMOUNT, balance);
        router.swap(
            key,
            SwapParams({
                zeroForOne: wrapZeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: _limit(wrapZeroForOne)
            }),
            ""
        );
        ghost_wraps++;
    }

    /// @notice Unwrap a bounded amount of shares into underlying as a random actor
    function unwrap(uint256 shares, uint256 actorSeed) external useActor(actorSeed) {
        uint256 balance = vault.balanceOf(currentActor);
        if (balance < MIN_AMOUNT) {
            ghost_skips++;
            return;
        }
        shares = bound(shares, MIN_AMOUNT, balance);
        router.swap(
            key,
            SwapParams({
                zeroForOne: !wrapZeroForOne,
                amountSpecified: -int256(shares),
                sqrtPriceLimitX96: _limit(!wrapZeroForOne)
            }),
            ""
        );
        ghost_unwraps++;
    }

    /// @notice Rebase the underlying up or down (dividends, splits, reverse splits). The hook makes
    /// @dev no directional assumption on the rate, so solvency must hold across arbitrary rebases.
    function rebase(uint256 rawMultiplier) external {
        underlying.setMultiplier(bound(rawMultiplier, 0.5e18, 5e18));
        ghost_rebases++;
    }

    function callSummary() external view {
        console2.log("wraps   ", ghost_wraps);
        console2.log("unwraps ", ghost_unwraps);
        console2.log("rebases ", ghost_rebases);
        console2.log("skips   ", ghost_skips);
    }
}

/// @title ERC4626 Wrapper Hook Invariants
/// @notice Handler-based invariant suite asserting the solvency and containment properties from the
/// @dev design doc (§6, §8, §13): the hook never overdraws the PoolManager, never retains wrapper
/// @dev shares, leaks at most bounded dust, and its pool never holds liquidity — all across random
/// @dev sequences of wraps, unwraps, and arbitrary rebases.
contract ERC4626WrapperHookInvariantTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    ERC4626WrapperHook internal hook;
    MockRebasingERC20 internal underlying;
    MockERC4626Vault internal vault;
    TestRouter internal router;
    ERC4626WrapperHandler internal handler;

    PoolKey internal poolKey;
    PoolId internal poolId;
    bool internal wrapZeroForOne;

    // Baselines captured after setup, in rebase-invariant units
    uint256 internal baselineManagerUnderlyingShares;
    uint256 internal baselineManagerVaultShares;

    function setUp() public {
        deployFreshManagerAndRouters();
        router = new TestRouter(manager);

        underlying = new MockRebasingERC20("Mock xStock", "AAPLx", 18);
        vault = new MockERC4626Vault(address(underlying), "Wrapped Mock xStock", "wAAPLx", 18);

        // Seed the vault with backing
        underlying.mint(address(this), 1_000_000 ether);
        underlying.approve(address(vault), type(uint256).max);
        vault.deposit(1_000_000 ether, address(this));

        // Deploy the hook at a flag-encoded address
        uint160 flags = uint160(
            type(uint160).max & clearAllHookPermissionsMask | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
        );
        hook = ERC4626WrapperHook(address(flags));
        deployCodeTo("ERC4626WrapperHook", abi.encode(manager, IERC4626(address(vault))), address(hook));

        wrapZeroForOne = address(underlying) < address(vault);
        (Currency currency0, Currency currency1) = wrapZeroForOne
            ? (Currency.wrap(address(underlying)), Currency.wrap(address(vault)))
            : (Currency.wrap(address(vault)), Currency.wrap(address(underlying)));
        poolKey = PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(hook)});
        poolId = poolKey.toId();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Seed the manager with a reserve buffer of both tokens so swaps always have reserves
        underlying.mint(address(manager), 1_000_000 ether);
        vault.transfer(address(manager), 500_000 ether);

        baselineManagerUnderlyingShares = underlying.sharesOf(address(manager));
        baselineManagerVaultShares = vault.balanceOf(address(manager));

        handler = new ERC4626WrapperHandler(router, underlying, vault, poolKey, wrapZeroForOne);

        // Only fuzz the handler's action functions
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ERC4626WrapperHandler.wrap.selector;
        selectors[1] = ERC4626WrapperHandler.unwrap.selector;
        selectors[2] = ERC4626WrapperHandler.rebase.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice §6/§13: the hook settles every wrapper share it mints — it is never a custodian
    function invariant_hookHoldsNoShares() public view {
        assertEq(vault.balanceOf(address(hook)), 0, "hook retains wrapper shares");
    }

    /// @notice §6: any leaked underlying stays as bounded dust in the hook (at most a few raw
    /// @dev shares per wrap; measured in rebase-invariant raw units so the bound is rate-agnostic)
    function invariant_hookUnderlyingIsBoundedDust() public view {
        assertLe(underlying.sharesOf(address(hook)), handler.ghost_wraps() * 4 + 4, "hook dust exceeds bound");
    }

    /// @notice §13 Solvency: the hook never overdraws the PoolManager. Its reserves of both tokens
    /// @dev never fall below the pre-campaign baseline (in raw/share units, invariant to rebases).
    function invariant_poolManagerNotDrained() public view {
        assertGe(underlying.sharesOf(address(manager)), baselineManagerUnderlyingShares, "manager underlying drained");
        assertGe(vault.balanceOf(address(manager)), baselineManagerVaultShares, "manager shares drained");
    }

    /// @notice §8: the hook pool never holds liquidity — the hook is the sole pricing mechanism
    function invariant_noPoolLiquidity() public view {
        assertEq(manager.getLiquidity(poolId), 0, "hook pool has liquidity");
    }

    function invariant_callSummary() public view {
        handler.callSummary();
    }
}
