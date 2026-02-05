// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FluidDexLiteAdminModule} from "lib/fluid-contracts-public/contracts/protocols/dexLite/adminModule/main.sol";
import {DexKey} from "lib/fluid-contracts-public/contracts/protocols/dexLite/other/structs.sol";
import {InitializeParams} from "lib/fluid-contracts-public/contracts/protocols/dexLite/adminModule/structs.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    FluidDexLiteAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregatorFactory.sol";
import {
    FluidDexLiteAggregator
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {
    IFluidDexLiteResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteResolver.sol";
import {IFluidDexLite} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

/// @title FluidDexLiteERC20Fuzz
/// @notice Fuzz tests for FluidDexLite through Uniswap V4 hooks (ERC20 tokens only)
/// @dev Creates random pools and executes multiple swaps to verify quote accuracy
contract FluidDexLiteERC20Fuzz is Test {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // Fluid Dex Lite contracts (from forked mainnet)
    IFluidDexLite public dexLite;
    address public dexLiteAdminModule;
    IFluidDexLiteResolver public resolver;
    address public fluidDexLiteAuth;

    // V4 contracts
    FluidDexLiteAggregatorFactory public hookFactory;
    PoolManager public poolManager;
    SafePoolSwapTest public swapRouter;

    // V4 Pool configuration
    uint24 constant POOL_FEE = 5; // 0.0005%
    int24 constant TICK_SPACING = 1;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Fluid Dex Lite pool parameter bounds
    uint256 constant MIN_FEE = 1; // 0.01% in basis points
    uint256 constant MAX_FEE = 100; // 1% in basis points
    uint256 constant MIN_RANGE_PERCENT = 100; // 0.01%
    uint256 constant MAX_RANGE_PERCENT = 10000; // 1%

    // Center price bounds (1e27 = 1:1 price)
    uint256 constant MIN_CENTER_PRICE = 1e26; // 0.1:1
    uint256 constant MAX_CENTER_PRICE = 1e28; // 10:1

    // Liquidity bounds
    uint256 constant MIN_LIQUIDITY = 1_000 ether;
    uint256 constant MAX_LIQUIDITY = 10_000_000 ether;

    // Swap bounds (relative to pool liquidity)
    uint256 constant MIN_SWAP_DIVISOR = 10000; // min swap = liquidity / 10000
    uint256 constant MAX_SWAP_DIVISOR = 100; // max swap = liquidity / 100

    address public alice = makeAddr("alice");

    /// @dev Struct to hold pool setup parameters (reduces stack depth)
    struct PoolSetup {
        MockERC20 token0;
        MockERC20 token1;
        DexKey dexKey;
        uint256 liquidity0;
        uint256 liquidity1;
        uint256 fee;
        uint256 rangePercent;
        uint256 centerPrice;
        bytes32 salt;
    }

    /// @dev Struct for hook deployment result
    struct HookDeployment {
        FluidDexLiteAggregator hook;
        PoolKey poolKey;
        PoolId poolId;
    }

    function setUp() public {
        // Forking requires an RPC URL env var
        string memory rpcUrl = vm.envString("FORK_RPC_URL");
        // Load Fluid infrastructure addresses from env vars
        dexLite = IFluidDexLite(vm.envAddress("FLUID_DEX_LITE"));
        dexLiteAdminModule = vm.envAddress("FLUID_DEX_LITE_ADMIN_MODULE");
        resolver = IFluidDexLiteResolver(vm.envAddress("FLUID_DEX_LITE_RESOLVER"));
        fluidDexLiteAuth = vm.envAddress("FLUID_DEX_LITE_AUTH");

        vm.createSelectFork(rpcUrl);

        // Deploy V4 infrastructure
        poolManager = new PoolManager(address(this));
        swapRouter = new SafePoolSwapTest(poolManager);
        hookFactory = new FluidDexLiteAggregatorFactory(IPoolManager(address(poolManager)), dexLite, resolver);
    }

    // ========== FUZZ TESTS ==========

    /// @notice Fuzz test: Exact input swaps, zeroForOne direction
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactIn_zeroForOne(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact input swaps (zeroForOne)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap(deployment, setup, seed, i, true);
        }
    }

    /// @notice Fuzz test: Exact input swaps, oneForZero direction
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactIn_oneForZero(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact input swaps (oneForZero)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap(deployment, setup, seed, i, false);
        }
    }

    /// @notice Fuzz test: Exact output swaps, zeroForOne direction
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactOut_zeroForOne(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact output swaps (zeroForOne)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactOutSwap(deployment, setup, seed, i, true);
        }
    }

    /// @notice Fuzz test: Exact output swaps, oneForZero direction
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactOut_oneForZero(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact output swaps (oneForZero)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactOutSwap(deployment, setup, seed, i, false);
        }
    }

    /// @notice Helper to setup pool and hook (reduces code duplication)
    function _setupPoolAndHook(uint256 seed)
        internal
        returns (PoolSetup memory setup, HookDeployment memory deployment)
    {
        setup = _derivePoolSetup(seed);
        _initializeFluidPool(setup);
        deployment = _deployHook(setup);
        _setupAlice(setup.token0, setup.token1, setup.liquidity0, setup.liquidity1);
    }

    // ========== POOL SETUP HELPERS ==========

    /// @notice Derive all pool parameters from a single seed
    function _derivePoolSetup(uint256 seed) internal returns (PoolSetup memory setup) {
        // Create sorted tokens
        (setup.token0, setup.token1) = _createSortedTokens(seed);

        // Derive pool parameters
        setup.liquidity0 = _deriveLiquidity(seed, 0);
        setup.liquidity1 = _deriveLiquidity(seed, 1);
        setup.fee = _deriveFee(seed);
        setup.rangePercent = _deriveRangePercent(seed);
        setup.centerPrice = _deriveCenterPrice(seed);
        setup.salt = keccak256(abi.encode(seed, "salt"));

        // Build dex key
        setup.dexKey = DexKey({token0: address(setup.token0), token1: address(setup.token1), salt: setup.salt});
    }

    /// @notice Create two mock tokens and sort by address
    function _createSortedTokens(uint256 seed) internal returns (MockERC20 token0, MockERC20 token1) {
        bytes32 salt0 = keccak256(abi.encode(seed, "token0"));
        bytes32 salt1 = keccak256(abi.encode(seed, "token1"));

        token0 = new MockERC20{salt: salt0}("Token0", "TK0", 18);
        token1 = new MockERC20{salt: salt1}("Token1", "TK1", 18);

        // Ensure token0 < token1
        if (address(token0) > address(token1)) {
            (token0, token1) = (token1, token0);
        }
    }

    /// @notice Initialize a Fluid Dex Lite pool
    function _initializeFluidPool(PoolSetup memory setup) internal {
        // Mint tokens to the auth address for pool initialization
        setup.token0.mint(fluidDexLiteAuth, setup.liquidity0);
        setup.token1.mint(fluidDexLiteAuth, setup.liquidity1);

        // Approve tokens
        vm.startPrank(fluidDexLiteAuth);
        setup.token0.approve(address(dexLite), setup.liquidity0);
        setup.token1.approve(address(dexLite), setup.liquidity1);
        vm.stopPrank();

        // Build initialization params
        InitializeParams memory initParams = InitializeParams({
            dexKey: setup.dexKey,
            revenueCut: 0,
            fee: setup.fee,
            rebalancingStatus: false,
            centerPrice: setup.centerPrice,
            centerPriceContract: 0,
            upperPercent: setup.rangePercent,
            lowerPercent: setup.rangePercent,
            upperShiftThreshold: 0,
            lowerShiftThreshold: 0,
            shiftTime: 3600,
            minCenterPrice: 1,
            maxCenterPrice: type(uint256).max,
            token0Amount: setup.liquidity0,
            token1Amount: setup.liquidity1
        });

        // Encode and execute initialization
        bytes memory initializeData = abi.encodeWithSelector(FluidDexLiteAdminModule.initialize.selector, initParams);
        bytes memory fallbackData = abi.encode(address(dexLiteAdminModule), initializeData);

        vm.prank(fluidDexLiteAuth);
        (bool success,) = address(dexLite).call(fallbackData);
        require(success, "Fluid pool initialization failed");
    }

    /// @notice Deploy V4 hook for the pool
    function _deployHook(PoolSetup memory setup) internal returns (HookDeployment memory deployment) {
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(poolManager), address(dexLite), address(resolver), setup.salt);

        (, bytes32 hookSalt) =
            HookMiner.find(address(hookFactory), flags, type(FluidDexLiteAggregator).creationCode, constructorArgs);

        address hookAddress = hookFactory.createPool(
            hookSalt,
            setup.salt,
            Currency.wrap(address(setup.token0)),
            Currency.wrap(address(setup.token1)),
            POOL_FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        deployment.hook = FluidDexLiteAggregator(payable(hookAddress));

        deployment.poolKey = PoolKey({
            currency0: Currency.wrap(address(setup.token0)),
            currency1: Currency.wrap(address(setup.token1)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        deployment.poolId = deployment.poolKey.toId();
    }

    /// @notice Setup alice with tokens and approvals
    function _setupAlice(MockERC20 token0, MockERC20 token1, uint256 amount0, uint256 amount1) internal {
        token0.mint(alice, amount0);
        token1.mint(alice, amount1);

        vm.startPrank(alice);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Seed PoolManager with tokens for swap settlements
        token0.mint(address(poolManager), amount0);
        token1.mint(address(poolManager), amount1);
    }

    // ========== SWAP HELPERS ==========

    /// @notice Execute an exact input swap and verify the output matches the quote
    /// @param zeroForOne Swap direction (true = token0 -> token1, false = token1 -> token0)
    function _executeExactInSwap(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal {
        // Derive swap amount
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity = setup.liquidity0 < setup.liquidity1 ? setup.liquidity0 : setup.liquidity1;
        uint256 amountIn = _deriveSwapAmount(swapSeed, minLiquidity);

        MockERC20 tokenIn = zeroForOne ? setup.token0 : setup.token1;
        MockERC20 tokenOut = zeroForOne ? setup.token1 : setup.token0;

        // Get quote before swap (negative amountSpecified = exact input)
        uint256 expectedOut = deployment.hook.quote(zeroForOne, -int256(amountIn), deployment.poolId);
        assertGt(expectedOut, 0, "Quote should be non-zero");

        uint256 tokenInBefore = tokenIn.balanceOf(alice);
        uint256 tokenOutBefore = tokenOut.balanceOf(alice);

        // Execute exact input swap
        vm.prank(alice);
        swapRouter.swap(
            deployment.poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 tokenInAfter = tokenIn.balanceOf(alice);
        uint256 tokenOutAfter = tokenOut.balanceOf(alice);

        // Verify exact input amount was spent
        assertEq(tokenInBefore - tokenInAfter, amountIn, "Should spend exact input amount");
        // Verify output matches quote
        assertEq(tokenOutAfter - tokenOutBefore, expectedOut, "Received amount should match quote");
    }

    /// @notice Execute an exact output swap and verify the input matches the quote
    /// @param zeroForOne Swap direction (true = token0 -> token1, false = token1 -> token0)
    function _executeExactOutSwap(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx,
        bool zeroForOne
    ) internal {
        // Derive swap amount (use smaller amounts for exact output to avoid slippage issues)
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity = setup.liquidity0 < setup.liquidity1 ? setup.liquidity0 : setup.liquidity1;
        // Use smaller amounts for exact output (1/10 of normal range)
        uint256 amountOut = _deriveSwapAmount(swapSeed, minLiquidity) / 10;
        // Ensure minimum amount
        if (amountOut == 0) amountOut = 1 ether;

        MockERC20 tokenIn = zeroForOne ? setup.token0 : setup.token1;
        MockERC20 tokenOut = zeroForOne ? setup.token1 : setup.token0;

        // Get quote before swap (positive amountSpecified = exact output)
        uint256 expectedIn = deployment.hook.quote(zeroForOne, int256(amountOut), deployment.poolId);
        assertGt(expectedIn, 0, "Quote should be non-zero");

        uint256 tokenInBefore = tokenIn.balanceOf(alice);
        uint256 tokenOutBefore = tokenOut.balanceOf(alice);

        // Execute exact output swap
        vm.prank(alice);
        swapRouter.swap(
            deployment.poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: int256(amountOut),
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 tokenInAfter = tokenIn.balanceOf(alice);
        uint256 tokenOutAfter = tokenOut.balanceOf(alice);

        // Verify exact output amount was received
        assertEq(tokenOutAfter - tokenOutBefore, amountOut, "Should receive exact output amount");
        // Verify input matches quote
        assertEq(tokenInBefore - tokenInAfter, expectedIn, "Input amount should match quote");
    }

    // ========== SEED-BASED DERIVATION HELPERS ==========

    /// @notice Derive liquidity amount for a token
    function _deriveLiquidity(uint256 seed, uint256 tokenIdx) internal pure returns (uint256) {
        return bound(uint256(keccak256(abi.encode(seed, "liquidity", tokenIdx))), MIN_LIQUIDITY, MAX_LIQUIDITY);
    }

    /// @notice Derive fee for the pool
    function _deriveFee(uint256 seed) internal pure returns (uint256) {
        return bound(uint256(keccak256(abi.encode(seed, "fee"))), MIN_FEE, MAX_FEE);
    }

    /// @notice Derive range percent for the pool
    function _deriveRangePercent(uint256 seed) internal pure returns (uint256) {
        return bound(uint256(keccak256(abi.encode(seed, "range"))), MIN_RANGE_PERCENT, MAX_RANGE_PERCENT);
    }

    /// @notice Derive center price for the pool
    function _deriveCenterPrice(uint256 seed) internal pure returns (uint256) {
        return bound(uint256(keccak256(abi.encode(seed, "centerPrice"))), MIN_CENTER_PRICE, MAX_CENTER_PRICE);
    }

    /// @notice Derive swap amount based on pool liquidity
    function _deriveSwapAmount(uint256 seed, uint256 liquidity) internal pure returns (uint256) {
        uint256 minSwap = liquidity / MIN_SWAP_DIVISOR;
        uint256 maxSwap = liquidity / MAX_SWAP_DIVISOR;
        return bound(uint256(keccak256(abi.encode(seed, "amount"))), minSwap, maxSwap);
    }

    receive() external payable {}
}
