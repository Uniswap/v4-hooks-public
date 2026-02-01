// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafePoolSwapTest} from "../test/aggregator-hooks/shared/SafePoolSwapTest.sol";

/// @notice Execute a swap through the hook
contract ExecuteSwap is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("TEMPO_TESTNET_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address router = vm.envAddress("ROUTER");
        address hook = vm.envAddress("HOOK");
        address token0 = vm.envAddress("TOKEN0");
        address token1 = vm.envAddress("TOKEN1");

        console.log("=== EXECUTING SWAP ===");
        console.log("Router:", router);
        console.log("Hook:", hook);
        console.log("");

        // Check balances before
        uint256 token0Before = IERC20(token0).balanceOf(deployer);
        uint256 token1Before = IERC20(token1).balanceOf(deployer);

        console.log("Balances BEFORE swap:");
        console.log("  pathUSD:", token0Before);
        console.log("  AlphaUSD:", token1Before);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Approve router
        IERC20(token0).approve(router, type(uint256).max);
        IERC20(token1).approve(router, type(uint256).max);

        // Create pool key
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 500,
            tickSpacing: 10,
            hooks: IHooks(hook)
        });

        // Execute swap: 100 pathUSD -> AlphaUSD (exact input)
        int256 amountSpecified = -100000000; // -100 tokens with 6 decimals

        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        console.log("Swapping 100 pathUSD for AlphaUSD...");

        SafePoolSwapTest(router).swap(
            poolKey, params, SafePoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), ""
        );

        vm.stopBroadcast();

        // Check balances after
        uint256 token0After = IERC20(token0).balanceOf(deployer);
        uint256 token1After = IERC20(token1).balanceOf(deployer);

        console.log("");
        console.log("Balances AFTER swap:");
        console.log("  pathUSD:", token0After);
        console.log("  AlphaUSD:", token1After);
        console.log("");
        console.log("Changes:");
        console.log("  pathUSD change:", int256(token0After) - int256(token0Before));
        console.log("  AlphaUSD change:", int256(token1After) - int256(token1Before));
        console.log("");
        console.log("SWAP EXECUTED SUCCESSFULLY!");
    }
}
