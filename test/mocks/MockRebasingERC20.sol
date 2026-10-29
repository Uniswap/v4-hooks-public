// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Mock Rebasing ERC20
/// @notice Minimal share-based rebasing token (stETH-style) for testing wrapper hooks
/// @dev Balances derive from internal shares and a global multiplier, so transfers round down
/// @dev by a few wei like real rebasing tokens. setMultiplier simulates a rebase.
contract MockRebasingERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;

    /// @notice Precision of the rebase multiplier (1e18 == 1.0x)
    uint256 internal constant ONE = 1e18;

    /// @notice Rebase multiplier scaled by 1e18. balance = shares * multiplier / 1e18
    uint256 public multiplier = ONE;

    /// @notice Internal, non-rebasing share balances
    mapping(address account => uint256 shares) public sharesOf;
    /// @notice Total internal shares
    uint256 public totalShares;

    mapping(address owner => mapping(address spender => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    /// @notice Converts a nominal token amount to shares, rounding down
    function _toShares(uint256 amount) internal view returns (uint256) {
        return (amount * ONE) / multiplier;
    }

    /// @notice Converts shares to a nominal token amount, rounding down
    function _toAmount(uint256 shares) internal view returns (uint256) {
        return (shares * multiplier) / ONE;
    }

    function totalSupply() public view returns (uint256) {
        return _toAmount(totalShares);
    }

    function balanceOf(address account) public view returns (uint256) {
        return _toAmount(sharesOf[account]);
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    /// @dev Moves a whole number of shares, so the recipient may receive a few wei less than `amount`
    function _transfer(address from, address to, uint256 amount) internal {
        uint256 shares = _toShares(amount);
        sharesOf[from] -= shares;
        sharesOf[to] += shares;
        emit Transfer(from, to, amount);
    }

    /// @notice Test helper: mint `amount` nominal tokens to `account`
    function mint(address account, uint256 amount) public {
        uint256 shares = _toShares(amount);
        sharesOf[account] += shares;
        totalShares += shares;
        emit Transfer(address(0), account, amount);
    }

    /// @notice Test helper: rebase by setting a new multiplier (1e18 == 1.0x). Scales all balances.
    function setMultiplier(uint256 newMultiplier) public {
        require(newMultiplier > 0, "multiplier=0");
        multiplier = newMultiplier;
    }
}
