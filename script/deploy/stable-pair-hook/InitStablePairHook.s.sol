// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StablePairHook} from "../../../src/stable/StablePairHook.sol";
import {Parameters, PoolParameters} from "./Parameters.sol";

/// @notice Initializes the StablePair pool defined by the current chain's PoolParameters.
///         The broadcaster must hold POOL_INITIALIZER_ROLE on the hook.
contract InitStablePairHookScript is Script, Parameters {
    /// @dev The hook only accepts dynamic-fee pools, so this is not configurable
    uint24 constant DYNAMIC_FEE = LPFeeLibrary.DYNAMIC_FEE_FLAG;

    function run() public {
        address hookAddress = vm.envAddress("HOOK_ADDRESS");
        PoolParameters memory pool = getPoolParameters(block.chainid);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(pool.currency0),
            currency1: Currency.wrap(pool.currency1),
            fee: DYNAMIC_FEE,
            tickSpacing: pool.tickSpacing,
            hooks: IHooks(hookAddress)
        });

        vm.broadcast();
        int24 tick = StablePairHook(hookAddress).initializePool(poolKey, pool.sqrtPriceX96, pool.feeConfig);
        console2.log("Pool initialized at tick:", tick);
    }
}
