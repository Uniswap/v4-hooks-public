// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITesseraPool} from "../../../../src/aggregator-hooks/implementations/Tessera/interfaces/ITesseraPool.sol";

/// @title MockTesseraPool
/// @notice Minimal mock that satisfies `ITesseraPool` view surface for the aggregator hook
contract MockTesseraPool is ITesseraPool {
    address public override baseToken;
    address public override quoteToken;
    uint8 public override baseTokenDecimal;
    uint8 public override quoteTokenDecimal;
    bool public override tradingEnabled;

    constructor(address _baseToken, address _quoteToken, uint8 _baseDecimal, uint8 _quoteDecimal, bool _enabled) {
        baseToken = _baseToken;
        quoteToken = _quoteToken;
        baseTokenDecimal = _baseDecimal;
        quoteTokenDecimal = _quoteDecimal;
        tradingEnabled = _enabled;
    }

    function setTradingEnabled(bool enabled) external {
        tradingEnabled = enabled;
    }
}
