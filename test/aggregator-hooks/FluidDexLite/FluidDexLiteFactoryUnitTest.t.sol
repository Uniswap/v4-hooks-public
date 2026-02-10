// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockFluidDexLite} from "./mocks/MockFluidDexLite.sol";
import {MockFluidDexLiteResolver} from "./mocks/MockFluidDexLiteResolver.sol";
import {
    FluidDexLiteAggregator
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregator.sol";
import {
    FluidDexLiteAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/FluidDexLite/FluidDexLiteAggregatorFactory.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

contract FluidDexLiteFactoryUnitTest is Test {
    PoolManager public poolManager;
    MockFluidDexLite public mockDex;
    MockFluidDexLiteResolver public mockResolver;
    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function setUp() public {
        poolManager = new PoolManager(address(this));
        mockDex = new MockFluidDexLite();
        mockResolver = new MockFluidDexLiteResolver();

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);
    }

    function test_factory_createPool() public {
        FluidDexLiteAggregatorFactory factory =
            new FluidDexLiteAggregatorFactory(IPoolManager(address(poolManager)), mockDex, mockResolver);

        MockERC20 tkA = new MockERC20("A", "A", 18);
        MockERC20 tkB = new MockERC20("B", "B", 18);
        if (address(tkA) > address(tkB)) (tkA, tkB) = (tkB, tkA);

        bytes32 dexSalt = bytes32(uint256(42));
        bytes memory args = abi.encode(address(poolManager), address(mockDex), address(mockResolver), dexSalt);
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(FluidDexLiteAggregator).creationCode,
            args
        );

        address hookAddr = factory.createPool(
            factorySalt,
            dexSalt,
            Currency.wrap(address(tkA)),
            Currency.wrap(address(tkB)),
            FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );
        assertTrue(hookAddr != address(0));
    }

    function test_factory_computeAddress_matchesDeployedAddress() public {
        FluidDexLiteAggregatorFactory factory =
            new FluidDexLiteAggregatorFactory(IPoolManager(address(poolManager)), mockDex, mockResolver);

        bytes32 dexSalt = bytes32(uint256(99));
        bytes memory args = abi.encode(address(poolManager), address(mockDex), address(mockResolver), dexSalt);
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG),
            type(FluidDexLiteAggregator).creationCode,
            args
        );

        address computed = factory.computeAddress(factorySalt, dexSalt);
        address deployed = factory.createPool(
            factorySalt,
            dexSalt,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            FEE,
            TICK_SPACING,
            SQRT_PRICE_1_1
        );

        assertEq(computed, deployed);
    }
}
