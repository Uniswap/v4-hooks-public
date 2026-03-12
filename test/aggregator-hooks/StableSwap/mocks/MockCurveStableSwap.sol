// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICurveStableSwap} from "../../../../src/aggregator-hooks/implementations/StableSwap/interfaces/IStableSwap.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title MockCurveStableSwap
/// @notice Mock Curve StableSwap pool with settable return values for unit tests.
contract MockCurveStableSwap is ICurveStableSwap {
    address[] public coinsList;
    mapping(uint256 => uint256) public balancesMap;
    uint256 public returnGetDy;
    uint256 public returnExchange;
    bool public revertGetDy;
    bool public revertExchange;

    error GetDyRevert();
    error ExchangeRevert();

    constructor(address[] memory _coins) {
        coinsList = _coins;
    }

    function setCoins(address[] calldata _coins) external {
        coinsList = _coins;
    }

    function setBalance(uint256 index, uint256 balance) external {
        balancesMap[index] = balance;
    }

    function setReturnGetDy(uint256 value) external {
        returnGetDy = value;
    }

    function setReturnExchange(uint256 value) external {
        returnExchange = value;
    }

    function setRevertGetDy(bool doRevert) external {
        revertGetDy = doRevert;
    }

    function setRevertExchange(bool doRevert) external {
        revertExchange = doRevert;
    }

    function coins(uint256 i) external view override returns (address) {
        if (i >= coinsList.length) return address(0);
        return coinsList[i];
    }

    function balances(uint256 i) external view override returns (uint256) {
        return balancesMap[i];
    }

    function get_dy(int128 i, int128 j, uint256 dx) external view override returns (uint256) {
        if (revertGetDy) revert GetDyRevert();
        (i, j, dx); // silence unused
        return returnGetDy;
    }

    function exchange(int128 i, int128 j, uint256 dx, uint256 min_dy) external payable override returns (uint256) {
        if (revertExchange) revert ExchangeRevert();
        // Transfer tokenIn from caller
        IERC20(coinsList[uint256(uint128(i))]).transferFrom(msg.sender, address(this), dx);
        // Transfer tokenOut to caller
        IERC20(coinsList[uint256(uint128(j))]).transfer(msg.sender, returnExchange);
        (min_dy); // silence unused
        return returnExchange;
    }
}
