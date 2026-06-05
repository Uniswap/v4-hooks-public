// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ILitePSM} from "../../../../src/aggregator-hooks/implementations/LitePSM/interfaces/ILitePSM.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockLitePSM
/// @notice Mock LitePSM for unit testing — simulates sellGem/buyGem with configurable tin/tout fees.
/// @dev Uses floor division for usdsAmt (matching the real PSM's internal math).
///      The mock acts as its own pocket so USDC balance queries go to address(this).
contract MockLitePSM is ILitePSM {
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;

    address private immutable _gem;
    address private immutable _usds;

    uint256 public tin; // fee on sellGem (USDC → USDS)
    uint256 public tout; // fee on buyGem (USDS → USDC)

    constructor(address gem_, address usds_) {
        _gem = gem_;
        _usds = usds_;
    }

    function gem() external view override returns (address) {
        return _gem;
    }

    function pocket() external view override returns (address) {
        return address(this);
    }

    function to18ConversionFactor() external pure override returns (uint256) {
        return 1e12;
    }

    /// @notice Sell gemAmt USDC, receive USDS at (WAD - tin) rate
    function sellGem(address usr, uint256 gemAmt) external override returns (uint256 usdsAmt) {
        usdsAmt = gemAmt * 1e12 * (WAD - tin) / WAD;
        IERC20(_gem).safeTransferFrom(msg.sender, address(this), gemAmt);
        IERC20(_usds).safeTransfer(usr, usdsAmt);
    }

    /// @notice Buy gemAmt USDC, pay USDS at (WAD + tout) rate
    function buyGem(address usr, uint256 gemAmt) external override returns (uint256 usdsAmt) {
        usdsAmt = gemAmt * 1e12 * (WAD + tout) / WAD;
        IERC20(_usds).safeTransferFrom(msg.sender, address(this), usdsAmt);
        IERC20(_gem).safeTransfer(usr, gemAmt);
    }

    function setTin(uint256 tin_) external {
        tin = tin_;
    }

    function setTout(uint256 tout_) external {
        tout = tout_;
    }
}
