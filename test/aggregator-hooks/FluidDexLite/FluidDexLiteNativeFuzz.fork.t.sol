// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {FluidDexLiteAdminModule} from "lib/fluid-contracts-public/contracts/protocols/dexLite/adminModule/main.sol";
import {DexKey} from "lib/fluid-contracts-public/contracts/protocols/dexLite/other/structs.sol";
import {InitializeParams} from "lib/fluid-contracts-public/contracts/protocols/dexLite/adminModule/structs.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV4FeeAdapter} from "@protocol-fees/interfaces/IV4FeeAdapter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {SafePoolSwapTest} from "../shared/SafePoolSwapTest.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";
import {
    FluidDexLiteAggregator
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {
    IFluidDexLiteResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLiteResolver.sol";
import {IFluidDexLite} from "../../../src/aggregator-hooks/implementations/FluidDexLite/interfaces/IFluidDexLite.sol";
import {
    FluidDexLiteAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregatorFactory.sol";

/// @title FluidDexLiteNativeFuzz
/// @notice Fuzz tests for FluidDexLite through Uniswap V4 hooks (Native ETH + ERC20 pairs)
/// @dev Creates random pools with native ETH and executes multiple swaps to verify quote accuracy
/// @dev Native ETH is always currency0 in Uniswap V4 (address(0) is the lowest address)
contract FluidDexLiteNativeFuzz is Test {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // Fluid's native currency representation
    address constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Fluid Dex Lite contracts (from forked mainnet)
    IFluidDexLite public dexLite;
    address public dexLiteAdminModule;
    IFluidDexLiteResolver public resolver;
    address public fluidDexLiteAuth;

    // V4 contracts
    FluidDexLiteAggregatorFactory public hookFactory;
    IPoolManager public poolManager;
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

    // Create alice address that doesn't have code on the forked chain (deterministic but unlikely to collide)
    address public alice = address(uint160(uint256(keccak256("fluid_dex_lite_test_alice_native_v1"))));

    /// @dev Struct to hold pool setup parameters (reduces stack depth)
    /// @dev For native pools: token0 is always native ETH (address(0) in V4), token1 is the ERC20
    struct PoolSetup {
        MockERC20 erc20Token; // The ERC20 token (token1 in V4 terms)
        DexKey dexKey;
        uint256 liquidityNative; // ETH liquidity (token0 in V4)
        uint256 liquidityErc20; // ERC20 liquidity (token1 in V4)
        uint256 fee;
        uint256 rangePercent;
        uint256 centerPrice; // Pool center price (1e27 = 1:1)
        bytes32 salt;
        bool ercIsFluidToken0; // True if ERC20 address < FLUID_NATIVE_CURRENCY
    }

    /// @dev Struct for hook deployment result
    struct HookDeployment {
        FluidDexLiteAggregator hook;
        PoolKey poolKey;
        PoolId poolId;
    }

    function setUp() public {
        // Forking requires an RPC URL env var and an optional block number
        string memory rpcUrl = vm.envString("FORK_RPC_URL");
        uint256 forkBlockNumber = vm.envOr("FORK_BLOCK_NUMBER", uint256(0));
        // Load Fluid infrastructure addresses from env vars
        dexLite = IFluidDexLite(vm.envAddress("FLUID_DEX_LITE"));
        dexLiteAdminModule = vm.envAddress("FLUID_DEX_LITE_ADMIN_MODULE");
        resolver = IFluidDexLiteResolver(vm.envAddress("FLUID_DEX_LITE_RESOLVER"));
        fluidDexLiteAuth = vm.envAddress("FLUID_DEX_LITE_AUTH");

        if (forkBlockNumber > 0) {
            vm.createSelectFork(rpcUrl, forkBlockNumber);
        } else {
            vm.createSelectFork(rpcUrl);
        }

        // Deploy V4 infrastructure
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));
        swapRouter = new SafePoolSwapTest(poolManager);
        hookFactory = new FluidDexLiteAggregatorFactory(poolManager, dexLite, resolver, IV4FeeAdapter(address(0)));
    }

    // ========== FUZZ TESTS ==========

    /// @notice Fuzz test: Exact input swaps, zeroForOne direction (Native ETH -> ERC20)
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactIn_zeroForOne(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact input swaps (zeroForOne: Native -> ERC20)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap_NativeIn(deployment, setup, seed, i);
        }
    }

    /// @notice Fuzz test: Exact input swaps, oneForZero direction (ERC20 -> Native ETH)
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactIn_oneForZero(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact input swaps (oneForZero: ERC20 -> Native)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactInSwap_ErcIn(deployment, setup, seed, i);
        }
    }

    /// @notice Fuzz test: Exact output swaps, zeroForOne direction (Native ETH -> ERC20)
    /// @dev This should revert because native exact-out is not supported
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactOut_zeroForOne_reverts(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Derive swap amount
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", 0)));
        uint256 minLiquidity =
            setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        // Use very small amounts for exact output (1/1000 of liquidity) to stay well within internal imaginary reserves
        uint256 amountOut = _deriveSwapAmount(swapSeed, minLiquidity) / 10;
        if (amountOut == 0) amountOut = 1 ether;

        // Expect revert for native exact-out
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(deployment.hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FluidDexLiteAggregator.NativeCurrencyExactOut.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        swapRouter.swap{value: amountOut * 2}(
            deployment.poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: int256(amountOut), // positive = exact output
                sqrtPriceLimitX96: MIN_PRICE_LIMIT
            }),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice Fuzz test: Exact output swaps, oneForZero direction (ERC20 -> Native ETH)
    /// @param seed Used to derive all random parameters deterministically
    function testFuzz_exactOut_oneForZero(uint256 seed) public {
        (PoolSetup memory setup, HookDeployment memory deployment) = _setupPoolAndHook(seed);

        // Execute 3 exact output swaps (oneForZero: ERC20 -> Native)
        for (uint256 i = 0; i < 3; i++) {
            _executeExactOutSwap_NativeOut(deployment, setup, seed, i);
        }
    }

    /// @notice Helper to setup pool and hook (reduces code duplication)
    function _setupPoolAndHook(uint256 seed)
        internal
        returns (PoolSetup memory setup, HookDeployment memory deployment)
    {
        setup = _derivePoolSetup(seed);
        bool success = _initializeFluidPool(setup);
        // Skip fuzz runs where pool initialization fails (Fluid has strict requirements for native pools)
        vm.assume(success);
        deployment = _deployHook(setup);
        _setupAlice(setup);
    }

    // ========== POOL SETUP HELPERS ==========

    /// @notice Derive all pool parameters from a single seed
    function _derivePoolSetup(uint256 seed) internal returns (PoolSetup memory setup) {
        // Create ERC20 token (will be token1 in V4 since address > address(0))
        setup.erc20Token = _createErc20Token(seed);

        // Derive pool parameters
        setup.liquidityNative = _deriveLiquidity(seed, 0);
        setup.liquidityErc20 = _deriveLiquidity(seed, 1);
        setup.fee = _deriveFee(seed);
        setup.rangePercent = _deriveRangePercent(seed);
        setup.centerPrice = _deriveCenterPrice(seed);
        setup.salt = keccak256(abi.encode(seed, "salt"));

        // Build dex key for Fluid (sorted: token0 < token1)
        // ERC20 could be either token0 or token1 depending on address comparison with FLUID_NATIVE_CURRENCY
        setup.ercIsFluidToken0 = address(setup.erc20Token) < FLUID_NATIVE_CURRENCY;
        if (setup.ercIsFluidToken0) {
            setup.dexKey = DexKey({token0: address(setup.erc20Token), token1: FLUID_NATIVE_CURRENCY, salt: setup.salt});
        } else {
            setup.dexKey = DexKey({token0: FLUID_NATIVE_CURRENCY, token1: address(setup.erc20Token), salt: setup.salt});
        }
    }

    /// @notice Create a mock ERC20 token
    function _createErc20Token(uint256 seed) internal returns (MockERC20 token) {
        bytes32 tokenSalt = keccak256(abi.encode(seed, "erc20Token"));
        token = new MockERC20{salt: tokenSalt}("Token", "TKN", 18);
    }

    /// @notice Initialize a Fluid Dex Lite pool with native ETH
    /// @return success Whether pool initialization succeeded
    function _initializeFluidPool(PoolSetup memory setup) internal returns (bool success) {
        // Mint ERC20 tokens to the auth address
        setup.erc20Token.mint(fluidDexLiteAuth, setup.liquidityErc20);
        // Deal ETH to the auth address for native liquidity
        vm.deal(fluidDexLiteAuth, setup.liquidityNative);

        // Approve ERC20 token
        vm.startPrank(fluidDexLiteAuth);
        setup.erc20Token.approve(address(dexLite), setup.liquidityErc20);
        vm.stopPrank();

        // Build initialization params
        // dexKey ordering (sorted): token0Amount and token1Amount must match dexKey ordering
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
            token0Amount: setup.ercIsFluidToken0 ? setup.liquidityErc20 : setup.liquidityNative,
            token1Amount: setup.ercIsFluidToken0 ? setup.liquidityNative : setup.liquidityErc20
        });

        // Encode and execute initialization
        bytes memory initializeData = abi.encodeWithSelector(FluidDexLiteAdminModule.initialize.selector, initParams);
        bytes memory fallbackData = abi.encode(address(dexLiteAdminModule), initializeData);

        vm.prank(fluidDexLiteAuth);
        (success,) = address(dexLite).call{value: setup.liquidityNative}(fallbackData);
    }

    /// @notice Deploy V4 hook for the pool
    function _deployHook(PoolSetup memory setup) internal returns (HookDeployment memory deployment) {
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(
            address(poolManager), address(dexLite), address(resolver), setup.salt, IV4FeeAdapter(address(0))
        );

        (, bytes32 hookSalt) =
            HookMiner.find(address(hookFactory), flags, type(FluidDexLiteAggregator).creationCode, constructorArgs);

        // In V4: currency0 = Native (address(0)), currency1 = ERC20
        address hookAddress = hookFactory.createPool(
            hookSalt,
            setup.salt,
            Currency.wrap(address(0)), // Native ETH is currency0
            Currency.wrap(address(setup.erc20Token)), // ERC20 is currency1
            POOL_FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        deployment.hook = FluidDexLiteAggregator(payable(hookAddress));

        deployment.poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(setup.erc20Token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        deployment.poolId = deployment.poolKey.toId();
    }

    /// @notice Setup alice with tokens and approvals
    function _setupAlice(PoolSetup memory setup) internal {
        // Deal ETH and mint ERC20 to alice
        vm.deal(alice, setup.liquidityNative);
        setup.erc20Token.mint(alice, setup.liquidityErc20);

        // Approve ERC20 for swap router (ETH doesn't need approval)
        vm.startPrank(alice);
        setup.erc20Token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Seed PoolManager with tokens for swap settlements
        vm.deal(address(poolManager), setup.liquidityNative);
        setup.erc20Token.mint(address(poolManager), setup.liquidityErc20);
    }

    // ========== SWAP HELPERS ==========

    /// @notice Execute an exact input swap: Native ETH -> ERC20 (zeroForOne)
    function _executeExactInSwap_NativeIn(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal {
        // Derive swap amount
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity =
            setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        uint256 amountIn = _deriveSwapAmount(swapSeed, minLiquidity);

        // Get quote before swap (negative amountSpecified = exact input)
        uint256 expectedOut = deployment.hook.quote(true, -int256(amountIn), deployment.poolId);
        assertGt(expectedOut, 0, "Quote should be non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = setup.erc20Token.balanceOf(alice);

        // Execute exact input swap with ETH value
        vm.prank(alice);
        swapRouter.swap{value: amountIn}(
            deployment.poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = setup.erc20Token.balanceOf(alice);

        // Verify ETH was spent (approximately, small variance for native handling)
        uint256 ethSpent = ethBefore - ethAfter;
        assertApproxEqRel(ethSpent, amountIn, 0.001e18, "ETH spent should be close to input amount");
        // Verify output matches quote
        assertEq(ercAfter - ercBefore, expectedOut, "Received amount should match quote");
    }

    /// @notice Execute an exact input swap: ERC20 -> Native ETH (oneForZero)
    function _executeExactInSwap_ErcIn(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal {
        // Derive swap amount
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity =
            setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        uint256 amountIn = _deriveSwapAmount(swapSeed, minLiquidity);

        // Get quote before swap (negative amountSpecified = exact input)
        uint256 expectedOut = deployment.hook.quote(false, -int256(amountIn), deployment.poolId);
        assertGt(expectedOut, 0, "Quote should be non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = setup.erc20Token.balanceOf(alice);

        // Execute exact input swap (no ETH value needed for ERC20 input)
        vm.prank(alice);
        swapRouter.swap(
            deployment.poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = setup.erc20Token.balanceOf(alice);

        // Verify ERC20 was spent
        assertEq(ercBefore - ercAfter, amountIn, "Should spend exact input amount");
        // Verify ETH output matches quote (approximately for native handling)
        uint256 ethReceived = ethAfter - ethBefore;
        assertApproxEqRel(ethReceived, expectedOut, 0.001e18, "ETH received should be close to quote");
    }

    /// @notice Execute an exact output swap: ERC20 -> Native ETH (oneForZero)
    function _executeExactOutSwap_NativeOut(
        HookDeployment memory deployment,
        PoolSetup memory setup,
        uint256 seed,
        uint256 swapIdx
    ) internal {
        // Derive swap amount (use smaller amounts for exact output)
        uint256 swapSeed = uint256(keccak256(abi.encode(seed, "swap", swapIdx)));
        uint256 minLiquidity =
            setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        uint256 amountOut = _deriveSwapAmount(swapSeed, minLiquidity) / 10;
        if (amountOut == 0) amountOut = 1 ether;

        // Get quote before swap (positive amountSpecified = exact output)
        uint256 expectedIn = deployment.hook.quote(false, int256(amountOut), deployment.poolId);
        assertGt(expectedIn, 0, "Quote should be non-zero");

        uint256 ethBefore = alice.balance;
        uint256 ercBefore = setup.erc20Token.balanceOf(alice);

        // Execute exact output swap
        vm.prank(alice);
        swapRouter.swap(
            deployment.poolKey,
            SwapParams({zeroForOne: false, amountSpecified: int256(amountOut), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 ethAfter = alice.balance;
        uint256 ercAfter = setup.erc20Token.balanceOf(alice);

        // Verify ETH output (approximately for native handling)
        uint256 ethReceived = ethAfter - ethBefore;
        assertApproxEqRel(ethReceived, amountOut, 0.001e18, "ETH received should be close to output amount");
        // Verify ERC20 input matches quote
        uint256 ercSpent = ercBefore - ercAfter;
        assertApproxEqRel(ercSpent, expectedIn, 0.001e18, "ERC20 spent should be close to quote");
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
