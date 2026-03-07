// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IAavePool} from "../../../src/propamm/interfaces/IAavePool.sol";

/// @title MockAavePool
/// @notice Simulates Aave V3 supply/withdraw with mock aTokens.
///         Each underlying has a 1:1 aToken. supply() transfers underlying from caller and
///         mints aTokens; withdraw() burns aTokens and transfers underlying to recipient.
contract MockAavePool is IAavePool {
    mapping(address => MockERC20) public aTokens;

    /// @notice Deploy a mock aToken for an underlying and return it.
    function addAsset(address underlying) external returns (address aToken) {
        string memory name = string.concat("a", MockERC20(underlying).name());
        string memory symbol = string.concat("a", MockERC20(underlying).symbol());
        MockERC20 token = new MockERC20(name, symbol, 18);
        aTokens[underlying] = token;
        return address(token);
    }

    function getAToken(address underlying) external view returns (address) {
        return address(aTokens[underlying]);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        aTokens[asset].mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        aTokens[asset].burn(msg.sender, amount);
        MockERC20(asset).transfer(to, amount);
        return amount;
    }

    /// @notice Simulate yield accrual by minting extra aTokens to a holder.
    function simulateYield(address underlying, address holder, uint256 yieldAmount) external {
        aTokens[underlying].mint(holder, yieldAmount);
    }
}
