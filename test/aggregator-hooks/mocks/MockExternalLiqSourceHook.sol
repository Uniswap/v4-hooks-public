// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BaseAggregatorHook} from "../../../src/aggregator-hooks/BaseAggregatorHook.sol";
import {MockExternalLiqSource} from "./MockExternalLiqSource.sol";

/// @title MockExternalLiqSourceHook
/// @notice Concrete BaseAggregatorHook that delegates _conductSwap to MockExternalLiqSource.
/// @dev quote and pseudoTotalValueLocked use settable storage for tests.
contract MockExternalLiqSourceHook is BaseAggregatorHook {
    MockExternalLiqSource public immutable externalSource;

    uint256 public mockQuoteReturn;
    uint256 public mockPseudoTVL0;
    uint256 public mockPseudoTVL1;

    constructor(IPoolManager _manager, MockExternalLiqSource _source) BaseAggregatorHook(_manager) {
        externalSource = _source;
    }

    function setMockQuoteReturn(uint256 amount) external {
        mockQuoteReturn = amount;
    }

    function setMockPseudoTVL(uint256 amount0, uint256 amount1) external {
        mockPseudoTVL0 = amount0;
        mockPseudoTVL1 = amount1;
    }

    function quote(bool, int256, PoolId) external payable override returns (uint256) {
        return mockQuoteReturn;
    }

    function pseudoTotalValueLocked(PoolId) external view override returns (uint256 amount0, uint256 amount1) {
        return (mockPseudoTVL0, mockPseudoTVL1);
    }

    function _conductSwap(Currency settleCurrency, Currency takeCurrency, SwapParams calldata params, PoolId)
        internal
        override
        returns (uint256 amountSettle, uint256 amountTake, bool hasSettled)
    {
        uint256 amountSpecifiedAbs =
            params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        (amountSettle, amountTake, hasSettled) =
            externalSource.pullTokens(settleCurrency, takeCurrency, amountSpecifiedAbs);
        poolManager.take(takeCurrency, address(this), amountTake);
        return (amountSettle, amountTake, hasSettled);
    }
}
