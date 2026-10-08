// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IIndexLpVault
/// @notice A passive index of `stock / index token` Uniswap v4 pools: one PositionManager position per pool, deposits routed
///         toward target weights, proportional redemptions. Shares are the vault's own ERC-20.
/// @dev Every amount is in token wei; every value (`nav`, `indexValue`, `valueInIndex`) is in index-token wei.
interface IIndexLpVault {
    /// @notice One constituent at deployment: its pool key (stock paired with the index token) and position range
    struct ConstituentInit {
        address stock;
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        int24 tickLower;
        int24 tickUpper;
        uint16 targetBps;
    }

    /// @notice A constituent as stored: `tokenId` is 0 until the first deposit that gives it liquidity mints its position
    struct ConstituentView {
        address stock;
        bytes32 poolId;
        uint256 tokenId;
        uint16 targetBps;
        int24 tickLower;
        int24 tickUpper;
    }

    event Deposit(address indexed from, address indexed to, uint256 shares, uint256 navAfter);
    event Redeem(address indexed from, address indexed to, uint256 shares, uint256 navAfter);
    event FeesCollected(uint256 navAfter);
    event Reranged(uint256 indexed i, int24 tickLower, int24 tickUpper, uint256 tokenId);
    event DepositsPaused(bool paused);

    /// @notice An amounts array does not have one entry per constituent
    error LengthMismatch();
    /// @notice Fewer shares minted than `minShares`, or less of a token paid out than its redeem minimum
    error SlippageExceeded();
    /// @notice Deposits are paused by the owner (redemptions never are)
    error DepositsArePaused();
    /// @notice The deposit would mint, or the redemption burns, zero shares
    error ZeroShares();

    /// @notice The token every pool pairs with and every value is expressed in
    function indexToken() external view returns (address);

    function constituentCount() external view returns (uint256);

    function constituent(uint256 i) external view returns (ConstituentView memory);

    /// @notice Positions valued at each pool's current price, plus the vault's idle balances; uncollected fees excluded
    function nav() external view returns (uint256 navInIndex);

    /// @notice Per constituent: its value (position plus idle stock), its share of `nav` in bps, and whether that share
    ///         is within `BAND_BPS` (relative) of its target
    function allocations()
        external
        view
        returns (uint256[] memory valueInIndex, uint16[] memory bps, bool[] memory inBand);

    /// @notice Per constituent: the pool's tick, the position's range, and how close the tick is to the nearer edge
    ///         (0 at the centre, 10000 at an edge, up to 20000 out of range)
    function rangeStatus()
        external
        view
        returns (
            int24[] memory currentTick,
            int24[] memory lower,
            int24[] memory upper,
            uint16[] memory edgeProximityBps
        );

    /// @notice The amounts a deposit worth `indexValue` should bring, routed toward target weights, and the shares it
    ///         mints at the current NAV
    function previewDeposit(uint256 indexValue)
        external
        view
        returns (uint256[] memory stockAmounts, uint256[] memory indexAmounts, uint256 shares);

    /// @notice What `redeem(shares, ...)` pays per constituent at the current prices, its idle share included
    function previewRedeem(uint256 shares) external view returns (uint256[] memory stockOut, uint256[] memory indexOut);

    /// @notice Per constituent the position's current token amounts, plus the vault's idle balance of each stock and of
    ///         the index token
    function holdings()
        external
        view
        returns (
            uint256[] memory positionStock,
            uint256[] memory positionIndex,
            uint256[] memory idleStock,
            uint256 idleIndex
        );

    /// @notice Adds `stockAmounts[i]` and `indexAmounts[i]` to constituent i's position (minting it on first use), returns
    ///         what the positions did not take to the caller and mints shares for the value added to `to`
    function deposit(uint256[] calldata stockAmounts, uint256[] calldata indexAmounts, uint256 minShares, address to)
        external
        returns (uint256 shares);

    /// @notice Burns the caller's `shares` and pays `to` the same fraction of every position and idle balance
    function redeem(uint256 shares, uint256[] calldata minStock, uint256[] calldata minIndex, address to)
        external
        returns (uint256[] memory stockOut, uint256[] memory indexOut);

    /// @notice Moves every position's accrued fees into the vault's idle balances, which count in `nav`
    function collectFees() external;

    /// @notice Owner: approves Permit2 for the eleven tokens and the PositionManager on Permit2. Idempotent.
    function setup() external;

    function setDepositsPaused(bool paused) external;

    /// @notice Owner: closes constituent i's position into the vault and re-mints the vault's balances of its two
    ///         tokens over `[tickLower, tickUpper)`
    function rerange(uint256 i, int24 tickLower, int24 tickUpper) external;
}
