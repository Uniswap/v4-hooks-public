// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITempoExchange} from
    "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITempoExchange.sol";
import {ITIP20} from "../src/aggregator-hooks/implementations/TempoExchange/interfaces/ITIP20.sol";
import {SafePoolSwapTest} from "../test/aggregator-hooks/shared/SafePoolSwapTest.sol";

/// @title InitializeTempoPools
/// @notice Discovers TIP-20 tokens via FFI, initializes V4 pools for each (token, quoteToken) pair,
///         seeds the hook for gas optimization, and executes a test swap per pool.
/// @dev Use env vars to target testnet vs prod:
///      - TEMPO_RPC_KEY: key in foundry.toml [rpc_endpoints] for token discovery (default "tempo_testnet"; use "tempo_mainnet" for prod)
///      - POOL_MANAGER, TEMPO_EXCHANGE, PATH_USD: contract addresses (testnet defaults below; set for prod)
contract InitializeTempoPools is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Default testnet addresses (Tempo Moderato, chain 42431)
    address constant DEFAULT_POOL_MANAGER = 0x72B37Ad2798c6C2B51C7873Ed2E291a88bB909a2;
    address constant DEFAULT_TEMPO_EXCHANGE = 0xDEc0000000000000000000000000000000000000;
    address constant DEFAULT_PATH_USD = 0x20C0000000000000000000000000000000000001;

    uint24 constant POOL_FEE = 500;
    int24 constant TICK_SPACING = 10;
    uint160 constant SQRT_PRICE_1_1 = 79_228_162_514_264_337_593_543_950_336;
    uint160 constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    // Default min liquidity: 1000 tokens at 6 decimals
    uint256 constant DEFAULT_MIN_LIQUIDITY = 1_000_000_000;

    struct PoolRecord {
        PoolKey key;
        PoolId id;
        string symbol0;
        string symbol1;
        uint256 tvl0;
        uint256 tvl1;
    }

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        address routerAddr = vm.envAddress("ROUTER_ADDRESS");
        address poolManager = vm.envOr("POOL_MANAGER", DEFAULT_POOL_MANAGER);
        address tempoExchange = vm.envOr("TEMPO_EXCHANGE", DEFAULT_TEMPO_EXCHANGE);
        address pathUsd = vm.envOr("PATH_USD", DEFAULT_PATH_USD);
        uint256 minLiquidity = vm.envOr("MIN_LIQUIDITY", DEFAULT_MIN_LIQUIDITY);
        string memory defaultRpcKey = "tempo_testnet";
        string memory rpcKey = vm.envOr("TEMPO_RPC_KEY", defaultRpcKey);
        string memory rpcUrl = vm.rpcUrl(rpcKey);

        IPoolManager pm = IPoolManager(poolManager);
        ITempoExchange exchange = ITempoExchange(tempoExchange);
        SafePoolSwapTest router = SafePoolSwapTest(payable(routerAddr));

        console.log("=== TEMPO POOL INITIALIZATION ===");
        console.log("Deployer:", deployer);
        console.log("Hook:", hookAddr);
        console.log("Router:", routerAddr);
        console.log("RPC key:", rpcKey);
        console.log("Min liquidity:", minLiquidity);

        // --- Step 1: Discover tokens via FFI ---
        string[] memory cmd = new string[](3);
        cmd[0] = "bash";
        cmd[1] = "script/util/fetch_tempo_tokens.sh";
        cmd[2] = rpcUrl;
        bytes memory result = vm.ffi(cmd);
        address[] memory tokens = abi.decode(result, (address[]));

        console.log("Discovered tokens:", tokens.length);

        // --- Step 2: Build qualifying pairs and initialize pools ---
        PoolRecord[] memory records = new PoolRecord[](tokens.length);
        uint256 poolCount = 0;

        vm.startBroadcast(deployerKey);

        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];

            // Skip root token (PathUSD has no parent pair)
            address parent = ITIP20(token).quoteToken();
            if (parent == address(0)) {
                console.log("Skipping root token:", ITIP20(token).symbol());
                continue;
            }

            // Check liquidity
            uint256 balance = IERC20(token).balanceOf(tempoExchange);
            if (balance < minLiquidity) {
                console.log("Skipping low-liquidity token:", ITIP20(token).symbol(), "balance:", balance);
                continue;
            }

            // Order tokens (lower address = currency0)
            address token0 = token < parent ? token : parent;
            address token1 = token < parent ? parent : token;

            PoolKey memory poolKey = PoolKey({
                currency0: Currency.wrap(token0),
                currency1: Currency.wrap(token1),
                fee: POOL_FEE,
                tickSpacing: TICK_SPACING,
                hooks: IHooks(hookAddr)
            });
            PoolId poolId = poolKey.toId();

            // 4a. Initialize pool (skip if already initialized)
            (uint160 sqrtPriceX96,,,) = pm.getSlot0(poolId);
            if (sqrtPriceX96 != 0) {
                console.log("");
                console.log("Skipping already initialized pool:", ITIP20(token0).symbol(), "/", ITIP20(token1).symbol());
                continue;
            }

            pm.initialize(poolKey, SQRT_PRICE_1_1);
            console.log("");
            console.log("Initialized pool:", ITIP20(token0).symbol(), "/", ITIP20(token1).symbol());

            // 4b. Seed hook with 1 unit of each token for gas optimization
            // For non-PathUSD tokens: buy 1 unit via the exchange, then transfer to hook
            // For PathUSD: transfer directly (deployer has PathUSD)
            _seedToken(token0, hookAddr, deployer, exchange, pathUsd);
            _seedToken(token1, hookAddr, deployer, exchange, pathUsd);
            console.log("  Seeded hook with 1 unit of each token");

            // 4c. Test swap (100 tokens exact-input, token0 → token1)
            uint256 swapAmount = 100 * 1e6;
            IERC20(token0).approve(routerAddr, type(uint256).max);
            IERC20(token1).approve(routerAddr, type(uint256).max);

            router.swap(
                poolKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(swapAmount),
                    sqrtPriceLimitX96: MIN_PRICE_LIMIT
                }),
                SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
            console.log("  Test swap OK (100 tokens)");

            // 4d. Record results
            uint256 tvl0 = IERC20(token0).balanceOf(tempoExchange);
            uint256 tvl1 = IERC20(token1).balanceOf(tempoExchange);

            records[poolCount] = PoolRecord({
                key: poolKey,
                id: poolId,
                symbol0: ITIP20(token0).symbol(),
                symbol1: ITIP20(token1).symbol(),
                tvl0: tvl0,
                tvl1: tvl1
            });
            poolCount++;
        }

        vm.stopBroadcast();

        // --- Step 3: Write results to docs/TempoPools.md ---
        string memory md = "# Tempo Pools\n\n";
        md = string.concat(md, "Auto-generated by `InitializeTempoPools` script.\n\n");
        md = string.concat(md, "| Pool | Token0 | Token1 | TVL0 | TVL1 | Pool ID |\n");
        md = string.concat(md, "|------|--------|--------|------|------|---------|\n");

        for (uint256 i = 0; i < poolCount; i++) {
            PoolRecord memory r = records[i];
            md = string.concat(
                md,
                "| ",
                r.symbol0,
                "/",
                r.symbol1,
                " | ",
                r.symbol0,
                " | ",
                r.symbol1,
                " | ",
                vm.toString(r.tvl0),
                " | ",
                vm.toString(r.tvl1),
                " | `",
                vm.toString(PoolId.unwrap(r.id)),
                "` |\n"
            );
        }

        md = string.concat(md, "\nTotal pools initialized: ", vm.toString(poolCount), "\n");

        vm.writeFile("docs/TempoPools.md", md);
        console.log("");
        console.log("=== COMPLETE ===");
        console.log("Pools initialized:", poolCount);
        console.log("Results written to docs/TempoPools.md");
    }

    /// @dev Seeds the hook with 1 unit of a token. For PathUSD (quote token), transfers directly.
    ///      For other tokens, buys 1 unit from the exchange using PathUSD, then transfers.
    function _seedToken(address token, address hook, address, ITempoExchange exchange, address pathUsd) internal {
        uint256 hookBalance = IERC20(token).balanceOf(hook);
        if (hookBalance > 0) return; // already seeded

        if (token == pathUsd) {
            // PathUSD: transfer 1 unit directly from deployer
            IERC20(pathUsd).transfer(hook, 1);
        } else {
            // Buy 1 unit of token via exchange, then transfer to hook
            IERC20(pathUsd).approve(address(exchange), type(uint256).max);
            exchange.swapExactAmountOut(pathUsd, token, 1, type(uint128).max);
            IERC20(token).transfer(hook, 1);
        }
    }
}
