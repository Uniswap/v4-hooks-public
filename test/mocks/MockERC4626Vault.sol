// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @notice Minimal subset of the ERC20 surface the vault needs from its (possibly rebasing) asset
interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @notice Optional observer notified while a deposit or redemption is still in flight
interface IVaultObserver {
    function onVaultCallback() external;
}

/// @title Mock ERC-4626 Vault
/// @notice Minimal, standard-rounding ERC-4626 vault for testing the ERC4626WrapperHook
/// @dev Share token is a normal (non-rebasing) ERC20. Conversions round in the vault's favor
/// @dev (deposit shares down, redeem assets down; mint/withdraw round the required amount up),
/// @dev matching the ERC-4626 rounding rules. `totalAssets()` reads the live asset balance, so a
/// @dev rebasing asset naturally moves the share/asset exchange rate.
contract MockERC4626Vault is ERC20 {
    error AssetTransferFailed();

    /// @notice The underlying asset token
    address public immutable asset;

    /// @notice When set, notified while a deposit or redemption is still in flight. Models a vault
    /// @notice that reaches third-party code mid-operation: a strategy adapter freeing funds, an AMM
    /// @notice leg in the withdrawal path, or a callback-capable asset. Unset by default, so the
    /// @notice vault behaves as a plain ERC-4626 vault unless a test opts in.
    address public observer;

    bool private _notifying;

    constructor(address _asset, string memory _name, string memory _symbol, uint8 _decimals)
        ERC20(_name, _symbol, _decimals)
    {
        asset = _asset;
    }

    function setObserver(address _observer) external {
        observer = _observer;
    }

    function totalAssets() public view returns (uint256) {
        return IERC20Like(asset).balanceOf(address(this));
    }

    function _mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y + d - 1) / d;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : _mulDivDown(assets, supply, totalAssets());
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : _mulDivDown(shares, totalAssets(), supply);
    }

    function previewDeposit(uint256 assets) public view virtual returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? shares : _mulDivUp(shares, totalAssets(), supply);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        return supply == 0 ? assets : _mulDivUp(assets, supply, totalAssets());
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    function deposit(uint256 assets, address receiver) public virtual returns (uint256 shares) {
        shares = previewDeposit(assets);
        if (!IERC20Like(asset).transferFrom(msg.sender, address(this), assets)) revert AssetTransferFailed();
        _mint(receiver, shares);
        _notifyObserver();
    }

    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = previewMint(shares);
        if (!IERC20Like(asset).transferFrom(msg.sender, address(this), assets)) revert AssetTransferFailed();
        _mint(receiver, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _spendAllowanceIfNeeded(owner, shares);
        _burn(owner, shares);
        if (!IERC20Like(asset).transfer(receiver, assets)) revert AssetTransferFailed();
    }

    function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets) {
        assets = previewRedeem(shares);
        _spendAllowanceIfNeeded(owner, shares);
        _burn(owner, shares);
        if (!IERC20Like(asset).transfer(receiver, assets)) revert AssetTransferFailed();
        _notifyObserver();
    }

    /// @notice Hands control to `observer`, if set, before the operation returns
    function _notifyObserver() internal {
        if (observer == address(0) || _notifying) return;
        _notifying = true;
        IVaultObserver(observer).onVaultCallback();
        _notifying = false;
    }

    function _spendAllowanceIfNeeded(address owner, uint256 shares) internal {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender];
            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }
    }
}
