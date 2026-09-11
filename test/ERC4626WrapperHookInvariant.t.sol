// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
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
/// @notice Drives randomized wrap, unwrap, and rebase actions across multiple actors
/// @dev Every completed action asserts its local balance changes
contract ERC4626WrapperHandler is Test {
    using SafeCast for uint256;

    TestRouter public immutable router;
    IPoolManager public immutable poolManager;
    MockRebasingERC20 public immutable underlying;
    MockERC4626Vault public immutable vault;
    PoolKey internal key;
    bool internal immutable wrapZeroForOne;

    uint256 internal constant MIN_AMOUNT = 1e12;

    address[] public actors;
    address internal currentActor;

    uint256 public ghost_wraps;

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
        poolManager = _router.poolManager();
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
            assertTrue(vault.transfer(actor, shares / 8));
            vm.startPrank(actor);
            underlying.approve(address(router), type(uint256).max);
            vault.approve(address(router), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _limit(bool zeroForOne) internal pure returns (uint160) {
        return zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// @notice Wraps a bounded amount of underlying as a randomized actor
    /// @param amount Seed used to select the input amount
    /// @param actorSeed Seed used to select the actor
    function wrap(uint256 amount, uint256 actorSeed) external useActor(actorSeed) {
        uint256 actorUnderlyingBefore = underlying.balanceOf(currentActor);
        if (actorUnderlyingBefore < MIN_AMOUNT) return;
        amount = bound(amount, MIN_AMOUNT, actorUnderlyingBefore);

        uint256 actorSharesBefore = vault.balanceOf(currentActor);
        uint256 managerUnderlyingSharesBefore = underlying.sharesOf(address(poolManager));
        uint256 managerVaultSharesBefore = vault.balanceOf(address(poolManager));

        router.swap(
            key,
            SwapParams({
                zeroForOne: wrapZeroForOne,
                amountSpecified: -amount.toInt256(),
                sqrtPriceLimitX96: _limit(wrapZeroForOne)
            }),
            ""
        );

        uint256 underlyingSpent = actorUnderlyingBefore - underlying.balanceOf(currentActor);
        uint256 sharesMinted = vault.balanceOf(currentActor) - actorSharesBefore;
        assertGt(underlyingSpent, 0, "wrap spent no underlying");
        assertLe(underlyingSpent, amount, "wrap overspent underlying");
        assertGt(sharesMinted, 0, "wrap minted no shares");
        assertGe(
            underlying.sharesOf(address(poolManager)), managerUnderlyingSharesBefore, "wrap drained manager underlying"
        );
        assertEq(vault.balanceOf(address(poolManager)), managerVaultSharesBefore, "wrap changed manager shares");
        assertEq(vault.balanceOf(address(key.hooks)), 0, "wrap left shares in hook");

        ghost_wraps++;
    }

    /// @notice Unwraps a bounded amount of shares as a randomized actor
    /// @param shares Seed used to select the input amount
    /// @param actorSeed Seed used to select the actor
    function unwrap(uint256 shares, uint256 actorSeed) external useActor(actorSeed) {
        uint256 actorSharesBefore = vault.balanceOf(currentActor);
        if (actorSharesBefore < MIN_AMOUNT) return;
        shares = bound(shares, MIN_AMOUNT, actorSharesBefore);

        uint256 actorUnderlyingBefore = underlying.balanceOf(currentActor);
        uint256 managerUnderlyingSharesBefore = underlying.sharesOf(address(poolManager));
        uint256 managerVaultSharesBefore = vault.balanceOf(address(poolManager));

        router.swap(
            key,
            SwapParams({
                zeroForOne: !wrapZeroForOne,
                amountSpecified: -shares.toInt256(),
                sqrtPriceLimitX96: _limit(!wrapZeroForOne)
            }),
            ""
        );

        uint256 underlyingReceived = underlying.balanceOf(currentActor) - actorUnderlyingBefore;
        assertEq(actorSharesBefore - vault.balanceOf(currentActor), shares, "unwrap burned incorrect shares");
        assertGt(underlyingReceived, 0, "unwrap returned no underlying");
        assertGe(
            underlying.sharesOf(address(poolManager)),
            managerUnderlyingSharesBefore,
            "unwrap drained manager underlying"
        );
        assertEq(vault.balanceOf(address(poolManager)), managerVaultSharesBefore, "unwrap changed manager shares");
        assertEq(vault.balanceOf(address(key.hooks)), 0, "unwrap left shares in hook");
    }

    /// @notice Rebases the underlying up or down without changing raw share accounting
    /// @param rawMultiplier Seed used to select the new multiplier
    function rebase(uint256 rawMultiplier) external {
        uint256 totalSharesBefore = underlying.totalShares();
        uint256 vaultSupplyBefore = vault.totalSupply();
        underlying.setMultiplier(bound(rawMultiplier, 0.5e18, 5e18));
        assertEq(underlying.totalShares(), totalSharesBefore, "rebase changed underlying shares");
        assertEq(vault.totalSupply(), vaultSupplyBefore, "rebase changed vault supply");
    }
}

/// @title ERC4626 Wrapper Hook Invariants
/// @notice Invariant tests for wrapper-hook solvency under randomized swaps and rebases
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

    uint256 internal constant MAX_DUST_WEI = 10_000; // 10_000 wei of dust is reasonable for a large number of invariant runs

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
        assertTrue(vault.transfer(address(manager), 500_000 ether));

        baselineManagerUnderlyingShares = underlying.sharesOf(address(manager));
        baselineManagerVaultShares = vault.balanceOf(address(manager));

        handler = new ERC4626WrapperHandler(router, underlying, vault, poolKey, wrapZeroForOne);
        underlying.setMultiplier(3e18);

        // Only fuzz the handler's action functions
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ERC4626WrapperHandler.wrap.selector;
        selectors[1] = ERC4626WrapperHandler.unwrap.selector;
        selectors[2] = ERC4626WrapperHandler.rebase.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice The hook settles every wrapper share it mints.
    function invariant_hookHoldsNoShares() public view {
        assertEq(vault.balanceOf(address(hook)), 0, "hook retains wrapper shares");
    }

    /// @notice Any underlying retained by the hook remains bounded rounding dust.
    function invariant_hookUnderlyingIsBoundedDust() public view {
        assertLe(underlying.sharesOf(address(hook)), MAX_DUST_WEI, "hook dust exceeds bound");
    }

    /// @notice PoolManager reserves never fall below their pre-campaign baselines.
    function invariant_poolManagerNotDrained() public view {
        assertGe(underlying.sharesOf(address(manager)), baselineManagerUnderlyingShares, "manager underlying drained");
        assertGe(vault.balanceOf(address(manager)), baselineManagerVaultShares, "manager shares drained");
    }

    /// @notice The wrapper pool never holds AMM liquidity.
    function invariant_noPoolLiquidity() public view {
        assertEq(manager.getLiquidity(poolId), 0, "hook pool has liquidity");
    }
}
