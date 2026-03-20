// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockCurveStableSwap} from "./mocks/MockCurveStableSwap.sol";
import {MockMetaRegistry} from "./mocks/MockMetaRegistry.sol";
import {MockV4FeeAdapter} from "../mocks/MockV4FeeAdapter.sol";
import {IMetaRegistry} from "../../../src/aggregator-hooks/implementations/StableSwap/interfaces/IMetaRegistry.sol";
import {StableSwapAggregator} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregator.sol";
import {
    StableSwapAggregatorFactory
} from "../../../src/aggregator-hooks/implementations/StableSwap/StableSwapAggregatorFactory.sol";
import {HookMiner} from "../../../src/utils/HookMiner.sol";

contract StableSwapFactoryUnitTest is Test {
    IPoolManager public poolManager;
    MockV4FeeAdapter public feeAdapter;
    MockCurveStableSwap public mockPool;
    MockMetaRegistry public mockMetaRegistry;
    MockERC20 public token0;
    MockERC20 public token1;

    uint24 constant FEE = 3000; // 0.3% fee
    int24 constant TICK_SPACING = 60; // Default tick spacing for a 0.3% fee pool
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 1:1 price

    function setUp() public {
        poolManager =
            IPoolManager(vm.deployCode("foundry-out/PoolManager.sol/PoolManager.json", abi.encode(address(this))));

        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);
        if (address(token0) > address(token1)) (token0, token1) = (token1, token0);

        address[] memory coins = new address[](2);
        coins[0] = address(token0);
        coins[1] = address(token1);
        mockPool = new MockCurveStableSwap(coins);
        mockMetaRegistry = new MockMetaRegistry();
        mockMetaRegistry.setIsRegistered(address(mockPool), true);
        feeAdapter = new MockV4FeeAdapter(poolManager, address(this));
    }

    function test_factory_createPool() public {
        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        MockERC20 tkA = new MockERC20("A", "A", 18);
        MockERC20 tkB = new MockERC20("B", "B", 18);
        if (address(tkA) > address(tkB)) (tkA, tkB) = (tkB, tkA);

        address[] memory coins2 = new address[](2);
        coins2[0] = address(tkA);
        coins2[1] = address(tkB);
        MockCurveStableSwap pool2 = new MockCurveStableSwap(coins2);
        mockMetaRegistry.setIsRegistered(address(pool2), true);

        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(address(tkA));
        tokens[1] = Currency.wrap(address(tkB));

        bytes memory args = abi.encode(address(poolManager), address(pool2), address(mockMetaRegistry));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(StableSwapAggregator).creationCode,
            args
        );

        address hookAddr = factory.createPool(factorySalt, pool2, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
        assertTrue(hookAddr != address(0));
    }

    function test_factory_computeAddress_matchesDeployedAddress() public {
        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        Currency[] memory tokens = new Currency[](2);
        tokens[0] = Currency.wrap(address(token0));
        tokens[1] = Currency.wrap(address(token1));

        bytes memory args = abi.encode(address(poolManager), address(mockPool), address(mockMetaRegistry));
        (, bytes32 factorySalt) = HookMiner.find(
            address(factory),
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_INITIALIZE_FLAG
                    | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ),
            type(StableSwapAggregator).creationCode,
            args
        );

        address computed = factory.computeAddress(factorySalt, mockPool);
        address deployed = factory.createPool(factorySalt, mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);

        assertEq(computed, deployed);
    }

    function test_factory_revertsInsufficientTokens() public {
        StableSwapAggregatorFactory factory =
            new StableSwapAggregatorFactory(poolManager, IMetaRegistry(address(mockMetaRegistry)));

        Currency[] memory tokens = new Currency[](1);
        tokens[0] = Currency.wrap(address(token0));

        vm.expectRevert(StableSwapAggregatorFactory.InsufficientTokens.selector);
        factory.createPool(bytes32(0), mockPool, tokens, FEE, TICK_SPACING, SQRT_PRICE_1_1);
    }
}
