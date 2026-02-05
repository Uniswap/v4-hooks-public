// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    FluidDexT1AggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1AggregatorFactory.sol";
import {FluidDexT1Aggregator} from "../../../src/aggregator-hooks/implementations/FluidDexT1/FluidDexT1Aggregator.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {
    IFluidDexReservesResolver
} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexReservesResolver.sol";
import {IFluidDexT1} from "../../../src/aggregator-hooks/implementations/FluidDexT1/interfaces/IFluidDexT1.sol";
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
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {IFluidDexFactory} from "./interfaces/IFluidDexFactory.sol";
import {IFluidDexT1DeploymentLogic} from "./interfaces/IFluidDexT1DeploymentLogic.sol";
import {IFluidLiquidityAdmin} from "./interfaces/IFluidLiquidityAdmin.sol";
import {IFluidDexT1Admin} from "./interfaces/IFluidDexT1Admin.sol";
import {AdminModuleStructs} from "./libraries/AdminModuleStructs.sol";
import {DexAdminStructs} from "./libraries/DexAdminStructs.sol";
import {MockLiquiditySupplier} from "./mocks/MockLiquiditySupplier.sol";

/// @title FluidDexT1NativeFuzz
/// @notice Fuzz tests for FluidDexT1 through Uniswap V4 hooks (Native ETH + ERC20 pairs)
/// @dev Creates random pools with native ETH and executes multiple swaps to verify quote accuracy
/// @dev Native ETH is always currency0 in Uniswap V4 (address(0) is the lowest address)
contract FluidDexT1NativeFuzz is Test {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    // Fluid's native currency representation
    address constant FLUID_NATIVE_CURRENCY = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Mainnet addresses (loaded from env vars)
    address liquidity;
    address dexFactoryAddress;
    address dexReservesResolver;
    address dexT1DeploymentLogic;
    address timelock;

    // Fluid contracts (loaded from mainnet fork)
    IFluidDexFactory public dexFactory;
    IFluidLiquidityAdmin public liquidityAdmin;
    IFluidDexT1DeploymentLogic public deploymentLogic;
    IFluidDexReservesResolver public resolver;
    MockLiquiditySupplier public liquiditySupplier;

    // V4 contracts
    FluidDexT1AggregatorFactory public hookFactory;
    PoolManager public poolManager;
    SafePoolSwapTest public swapRouter;

    // V4 Pool configuration
    uint24 constant POOL_FEE = 5; // 0.0005%
    int24 constant TICK_SPACING = 1;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    // Price limits for swaps
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Pool parameter bounds
    uint256 constant MIN_FEE = 0; // 0% in basis points (1e4 = 1%)
    uint256 constant MAX_FEE = 1000; // 0.1% in basis points
    uint256 constant MIN_RANGE_PERCENT = 1 * 1e4; // 1% (1e4 = 1%)
    uint256 constant MAX_RANGE_PERCENT = 20 * 1e4; // 20%

    // Center price bounds (1e27 = 1:1 price)
    uint256 constant MIN_CENTER_PRICE = 5e26; // 0.5:1
    uint256 constant MAX_CENTER_PRICE = 2e27; // 2:1

    // Center price limit bounds (as percentage deviation from center price, in 1e4 units)
    uint256 constant MIN_CENTER_PRICE_DEVIATION = 10 * 1e4; // 10% deviation
    uint256 constant MAX_CENTER_PRICE_DEVIATION = 30 * 1e4; // 30% deviation

    // Shift threshold bounds (in 1e4 units, 1e4 = 1%)
    uint256 constant MIN_SHIFT_THRESHOLD = 3 * 1e4; // 3%
    uint256 constant MAX_SHIFT_THRESHOLD = 8 * 1e4; // 8%

    // Liquidity bounds
    // Note: For native pools, we rely on mainnet's existing liquidity layer supply
    // Keep amounts small to stay within mainnet's configured limits
    uint256 constant MIN_LIQUIDITY = 10 ether;
    uint256 constant MAX_LIQUIDITY = 100 ether;

    // Swap bounds (relative to pool liquidity)
    uint256 constant MIN_SWAP_DIVISOR = 10000; // min swap = liquidity / 10000
    uint256 constant MAX_SWAP_DIVISOR = 100; // max swap = liquidity / 100

    // Create alice address that doesn't have code on mainnet
    address public alice = address(uint160(uint256(keccak256("fluid_dex_t1_test_alice_native_fuzz_v1"))));

    /// @dev Struct to hold pool setup parameters (reduces stack depth)
    /// @dev For native pools: token0 is always native ETH (address(0) in V4), token1 is the ERC20
    struct PoolSetup {
        MockERC20 erc20Token; // The ERC20 token (token1 in V4 terms)
        address fluidPool;
        uint256 liquidityNative; // ETH liquidity (token0 in V4)
        uint256 liquidityErc20; // ERC20 liquidity (token1 in V4)
        uint256 fee;
        uint256 rangePercent;
        uint256 centerPrice; // Pool center price (1e27 = 1:1)
        uint256 maxCenterPrice; // Maximum allowed center price
        uint256 minCenterPrice; // Minimum allowed center price
        uint256 upperShiftThreshold; // Upper shift threshold (1e4 = 1%)
        uint256 lowerShiftThreshold; // Lower shift threshold (1e4 = 1%)
        bool ercIsFluidToken0; // True if ERC20 address < FLUID_NATIVE_CURRENCY
    }

    /// @dev Struct for hook deployment result
    struct HookDeployment {
        FluidDexT1Aggregator hook;
        PoolKey poolKey;
        PoolId poolId;
    }

    function setUp() public {
        // Forking requires an RPC URL env var
        string memory rpcUrl = vm.envString("FORK_RPC_URL");
        // Load Fluid infrastructure addresses from env vars
        liquidity = vm.envAddress("FLUID_LIQUIDITY");
        dexFactoryAddress = vm.envAddress("FLUID_DEX_T1_FACTORY");
        dexReservesResolver = vm.envAddress("FLUID_DEX_T1_RESOLVER");
        dexT1DeploymentLogic = vm.envAddress("FLUID_DEX_T1_DEPLOYMENT_LOGIC");
        timelock = vm.envAddress("FLUID_DEX_T1_TIMELOCK");

        vm.createSelectFork(rpcUrl);

        // Load mainnet contracts
        dexFactory = IFluidDexFactory(dexFactoryAddress);
        liquidityAdmin = IFluidLiquidityAdmin(liquidity);
        deploymentLogic = IFluidDexT1DeploymentLogic(dexT1DeploymentLogic);
        resolver = IFluidDexReservesResolver(dexReservesResolver);

        // Deploy liquidity supplier for prefunding
        liquiditySupplier = new MockLiquiditySupplier(liquidity);

        // Add this test contract as a deployer and global auth
        vm.startPrank(timelock);
        dexFactory.setDeployer(address(this), true);
        dexFactory.setGlobalAuth(address(this), true);
        vm.stopPrank();

        // Deploy V4 infrastructure
        poolManager = new PoolManager(address(this));
        swapRouter = new SafePoolSwapTest(poolManager);
        hookFactory = new FluidDexT1AggregatorFactory(
            IPoolManager(address(poolManager)), IFluidDexReservesResolver(dexReservesResolver), liquidity
        );
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
        uint256 amountOut = _deriveSwapAmount(swapSeed, minLiquidity) / 10;
        if (amountOut == 0) amountOut = 1 ether;

        // Expect revert for native exact-out
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(deployment.hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(FluidDexT1Aggregator.NativeCurrencyExactOut.selector),
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
        _configureTokensInLiquidity(setup);
        _deployAndInitializeFluidPool(setup);
        deployment = _deployHook(setup);
        _setupAlice(setup);
    }

    // ========== POOL SETUP HELPERS ==========

    /// @notice Derive all pool parameters from a single seed
    function _derivePoolSetup(uint256 seed) internal returns (PoolSetup memory setup) {
        // Create ERC20 token (will be token1 in V4 since address(0) is always lowest)
        setup.erc20Token = _createErc20Token(seed);

        // Derive pool parameters
        setup.liquidityNative = _deriveLiquidity(seed, 0);
        setup.liquidityErc20 = _deriveLiquidity(seed, 1);
        setup.fee = _deriveFee(seed);
        setup.rangePercent = _deriveRangePercent(seed);
        setup.centerPrice = _deriveCenterPrice(seed);
        (setup.minCenterPrice, setup.maxCenterPrice) = _deriveCenterPriceLimits(seed, setup.centerPrice);
        setup.upperShiftThreshold = _deriveShiftThreshold(seed, 0);
        setup.lowerShiftThreshold = _deriveShiftThreshold(seed, 1);

        // Determine Fluid token ordering (ERC20 vs FLUID_NATIVE_CURRENCY)
        setup.ercIsFluidToken0 = address(setup.erc20Token) < FLUID_NATIVE_CURRENCY;
    }

    /// @notice Create a mock ERC20 token
    function _createErc20Token(uint256 seed) internal returns (MockERC20 token) {
        bytes32 tokenSalt = keccak256(abi.encode(seed, "erc20Token"));
        token = new MockERC20{salt: tokenSalt}("Token", "TKN", 18);
    }

    /// @notice Configure tokens in the Liquidity layer (rate data + token config)
    function _configureTokensInLiquidity(PoolSetup memory setup) internal {
        vm.startPrank(timelock);

        // Configure rate data for ERC20 token (native is already configured on mainnet)
        AdminModuleStructs.RateDataV1Params[] memory rateParams = new AdminModuleStructs.RateDataV1Params[](1);
        rateParams[0] = AdminModuleStructs.RateDataV1Params({
            token: address(setup.erc20Token),
            kink: 8000, // 80%
            rateAtUtilizationZero: 0,
            rateAtUtilizationKink: 1000, // 10%
            rateAtUtilizationMax: 2000 // 20%
        });
        liquidityAdmin.updateRateDataV1s(rateParams);

        // Configure token settings for ERC20
        AdminModuleStructs.TokenConfig[] memory tokenConfigs = new AdminModuleStructs.TokenConfig[](1);
        tokenConfigs[0] = AdminModuleStructs.TokenConfig({
            token: address(setup.erc20Token),
            fee: 0,
            threshold: 0,
            maxUtilization: 10000 // 100%
        });
        liquidityAdmin.updateTokenConfigs(tokenConfigs);

        vm.stopPrank();
    }

    /// @notice Deploy and initialize a Fluid DexT1 pool with native ETH
    function _deployAndInitializeFluidPool(PoolSetup memory setup) internal {
        // Calculate liquidity multiplier based on max possible center price ratio
        // Due to price ratio, plus generous buffer for fees/rounding/multi-use
        uint256 priceMultiplier = ((MAX_CENTER_PRICE / 1e27) + 1) * 3; // e.g., (10 + 1) * 3 = 33x

        // Mint ERC20 tokens (need extra for: liquidity layer supply, pool init, alice, poolManager)
        uint256 totalMintErc = setup.liquidityErc20 * priceMultiplier;
        setup.erc20Token.mint(address(this), totalMintErc);

        // Deal ETH to this contract for native liquidity
        vm.deal(address(this), setup.liquidityNative * priceMultiplier);

        // Deploy pool via factory
        setup.fluidPool = _deployFluidPool(setup);

        // Configure liquidity allowances
        _configureAllowances(setup, totalMintErc);

        // Prefund the liquidity layer
        _prefundLiquidity(setup);

        // Initialize the pool
        _initializePool(setup);
    }

    /// @notice Deploy the Fluid pool
    function _deployFluidPool(PoolSetup memory setup) internal returns (address) {
        address fluidToken0;
        address fluidToken1;
        if (setup.ercIsFluidToken0) {
            fluidToken0 = address(setup.erc20Token);
            fluidToken1 = FLUID_NATIVE_CURRENCY;
        } else {
            fluidToken0 = FLUID_NATIVE_CURRENCY;
            fluidToken1 = address(setup.erc20Token);
        }

        bytes memory creationCode = abi.encodeCall(deploymentLogic.dexT1, (fluidToken0, fluidToken1, 1e4));
        return dexFactory.deployDex(dexT1DeploymentLogic, creationCode);
    }

    /// @notice Configure allowances for the pool
    function _configureAllowances(PoolSetup memory setup, uint256 totalMintErc) internal {
        uint256 priceMultiplier = ((MAX_CENTER_PRICE / 1e27) + 1) * 3;
        _setUserAllowancesDefault(address(setup.erc20Token), address(liquiditySupplier), totalMintErc);
        _setUserAllowancesDefault(address(setup.erc20Token), setup.fluidPool, totalMintErc);
        _setUserAllowancesNative(setup.fluidPool, setup.liquidityNative * priceMultiplier);
    }

    /// @notice Prefund the liquidity layer
    /// @dev Only prefunds ERC20 tokens - native ETH relies on existing mainnet liquidity
    function _prefundLiquidity(PoolSetup memory setup) internal {
        uint256 prefundAmountErc = setup.liquidityErc20 * 2;
        setup.erc20Token.approve(address(liquiditySupplier), prefundAmountErc);
        setup.erc20Token.approve(liquidity, prefundAmountErc);
        liquiditySupplier.supply(address(setup.erc20Token), prefundAmountErc, address(this));
        // Note: Native ETH is not prefunded - we rely on mainnet's existing liquidity layer supply
    }

    /// @notice Initialize the Fluid pool
    function _initializePool(PoolSetup memory setup) internal {
        uint256 initAmount = setup.liquidityNative < setup.liquidityErc20 ? setup.liquidityNative : setup.liquidityErc20;
        setup.erc20Token.approve(setup.fluidPool, initAmount * 2);

        DexAdminStructs.InitializeVariables memory initParams = _buildInitParams(setup, initAmount);

        // Calculate ETH value based on center price and token ordering
        // If ERC20 is token0: ETH (token1) amount = centerPrice * token0Amt / 1e27
        // If ETH is token0: ETH amount = token0Amt
        uint256 ethValue;
        if (setup.ercIsFluidToken0) {
            // ERC20 is token0, ETH is token1: need (centerPrice * initAmount / 1e27) ETH
            // Add buffer for precision and rounding
            ethValue = (setup.centerPrice * initAmount * 2) / 1e27;
        } else {
            // ETH is token0: need initAmount ETH (plus buffer)
            ethValue = initAmount * 2;
        }
        IFluidDexT1Admin(setup.fluidPool).initialize{value: ethValue}(initParams);
        IFluidDexT1Admin(setup.fluidPool).toggleOracleActivation(true);
    }

    /// @notice Build initialization parameters
    function _buildInitParams(PoolSetup memory setup, uint256 initAmount)
        internal
        pure
        returns (DexAdminStructs.InitializeVariables memory)
    {
        return DexAdminStructs.InitializeVariables({
            smartCol: true,
            token0ColAmt: initAmount,
            smartDebt: true,
            token0DebtAmt: initAmount,
            centerPrice: setup.centerPrice,
            fee: setup.fee,
            revenueCut: 0,
            upperPercent: setup.rangePercent,
            lowerPercent: setup.rangePercent,
            upperShiftThreshold: setup.upperShiftThreshold,
            lowerShiftThreshold: setup.lowerShiftThreshold,
            thresholdShiftTime: 1 days,
            centerPriceAddress: 0,
            hookAddress: 0,
            maxCenterPrice: setup.maxCenterPrice,
            minCenterPrice: setup.minCenterPrice
        });
    }

    /// @notice Set user supply and borrow allowances for an ERC20 token/pool pair
    function _setUserAllowancesDefault(address token, address pool, uint256 tokenTotalSupply) internal {
        vm.startPrank(timelock);

        // Supply config
        AdminModuleStructs.UserSupplyConfig[] memory supplyConfigs = new AdminModuleStructs.UserSupplyConfig[](1);
        supplyConfigs[0] = AdminModuleStructs.UserSupplyConfig({
            user: pool,
            token: token,
            mode: 1, // with interest
            expandPercent: 2500, // 25%
            expandDuration: 12 hours,
            baseWithdrawalLimit: tokenTotalSupply
        });
        liquidityAdmin.updateUserSupplyConfigs(supplyConfigs);

        // Borrow config - maxDebtCeiling must be <= 10 * totalSupply
        uint256 maxDebt = tokenTotalSupply * 9;
        AdminModuleStructs.UserBorrowConfig[] memory borrowConfigs = new AdminModuleStructs.UserBorrowConfig[](1);
        borrowConfigs[0] = AdminModuleStructs.UserBorrowConfig({
            user: pool,
            token: token,
            mode: 1, // with interest
            expandPercent: 2500,
            expandDuration: 12 hours,
            baseDebtCeiling: maxDebt,
            maxDebtCeiling: maxDebt
        });
        liquidityAdmin.updateUserBorrowConfigs(borrowConfigs);

        vm.stopPrank();
    }

    /// @notice Set user supply and borrow allowances for native ETH
    function _setUserAllowancesNative(address pool, uint256 amount) internal {
        vm.startPrank(timelock);

        // Supply config for native
        AdminModuleStructs.UserSupplyConfig[] memory supplyConfigs = new AdminModuleStructs.UserSupplyConfig[](1);
        supplyConfigs[0] = AdminModuleStructs.UserSupplyConfig({
            user: pool,
            token: FLUID_NATIVE_CURRENCY,
            mode: 1, // with interest
            expandPercent: 2500, // 25%
            expandDuration: 12 hours,
            baseWithdrawalLimit: amount
        });
        liquidityAdmin.updateUserSupplyConfigs(supplyConfigs);

        // Borrow config for native
        uint256 maxDebt = amount * 9;
        AdminModuleStructs.UserBorrowConfig[] memory borrowConfigs = new AdminModuleStructs.UserBorrowConfig[](1);
        borrowConfigs[0] = AdminModuleStructs.UserBorrowConfig({
            user: pool,
            token: FLUID_NATIVE_CURRENCY,
            mode: 1, // with interest
            expandPercent: 2500,
            expandDuration: 12 hours,
            baseDebtCeiling: maxDebt,
            maxDebtCeiling: maxDebt
        });
        liquidityAdmin.updateUserBorrowConfigs(borrowConfigs);

        vm.stopPrank();
    }

    /// @notice Deploy V4 hook for the pool
    function _deployHook(PoolSetup memory setup) internal returns (HookDeployment memory deployment) {
        uint160 flags =
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG);

        bytes memory constructorArgs = abi.encode(address(poolManager), setup.fluidPool, address(resolver), liquidity);

        (, bytes32 hookSalt) =
            HookMiner.find(address(hookFactory), flags, type(FluidDexT1Aggregator).creationCode, constructorArgs);

        // In V4: currency0 = Native (address(0)), currency1 = ERC20
        address hookAddress = hookFactory.createPool(
            hookSalt,
            IFluidDexT1(setup.fluidPool),
            Currency.wrap(address(0)), // Native ETH is currency0
            Currency.wrap(address(setup.erc20Token)), // ERC20 is currency1
            POOL_FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        deployment.hook = FluidDexT1Aggregator(payable(hookAddress));

        deployment.poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // Native ETH
            currency1: Currency.wrap(address(setup.erc20Token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        deployment.poolId = deployment.poolKey.toId();
    }

    /// @notice Setup alice with tokens and approvals
    function _setupAlice(PoolSetup memory setup) internal {
        // Calculate multiplier based on max center price ratio for sufficient swap funds
        uint256 priceMultiplier = ((MAX_CENTER_PRICE / 1e27) + 1) * 3;

        // Deal ETH and mint ERC20 to alice
        vm.deal(alice, setup.liquidityNative * priceMultiplier);
        setup.erc20Token.mint(alice, setup.liquidityErc20 * priceMultiplier);

        // Approve ERC20 for swap router (ETH doesn't need approval)
        vm.startPrank(alice);
        setup.erc20Token.approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();

        // Seed PoolManager with tokens for swap settlements
        vm.deal(address(poolManager), setup.liquidityNative * priceMultiplier);
        setup.erc20Token.mint(address(poolManager), setup.liquidityErc20 * priceMultiplier);
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
        uint256 amountOut = minLiquidity / 1000;
        // Add some variation based on seed
        amountOut = bound(uint256(keccak256(abi.encode(swapSeed, "exactOut"))), amountOut / 10, amountOut);
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

        // Verify ETH output (approximately for native handling and Fluid's exactOut inaccuracy)
        uint256 ethReceived = ethAfter - ethBefore;
        assertApproxEqAbs(ethReceived, amountOut, 1, "ETH received should be close to output amount");
        // Verify ERC20 input matches quote
        uint256 ercSpent = ercBefore - ercAfter;
        assertEq(ercSpent, expectedIn, "ERC20 spent should match quote");
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

    /// @notice Derive min and max center price limits based on center price
    function _deriveCenterPriceLimits(uint256 seed, uint256 centerPrice)
        internal
        pure
        returns (uint256 minPrice, uint256 maxPrice)
    {
        uint256 deviation = bound(
            uint256(keccak256(abi.encode(seed, "priceDeviation"))),
            MIN_CENTER_PRICE_DEVIATION,
            MAX_CENTER_PRICE_DEVIATION
        );
        // deviation is in 1e4 units (1e4 = 1%), so divide by 1e6 to get the multiplier
        minPrice = centerPrice - (centerPrice * deviation) / 1e6;
        maxPrice = centerPrice + (centerPrice * deviation) / 1e6;
    }

    /// @notice Derive shift threshold
    function _deriveShiftThreshold(uint256 seed, uint256 idx) internal pure returns (uint256) {
        return
            bound(uint256(keccak256(abi.encode(seed, "shiftThreshold", idx))), MIN_SHIFT_THRESHOLD, MAX_SHIFT_THRESHOLD);
    }

    /// @notice Derive swap amount based on pool liquidity
    function _deriveSwapAmount(uint256 seed, uint256 poolLiquidity) internal pure returns (uint256) {
        uint256 minSwap = poolLiquidity / MIN_SWAP_DIVISOR;
        uint256 maxSwap = poolLiquidity / MAX_SWAP_DIVISOR;
        return bound(uint256(keccak256(abi.encode(seed, "amount"))), minSwap, maxSwap);
    }

    receive() external payable {}
}
