// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {BaseHook} from "../base/BaseHook.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title NativeBookHook
/// @author Uniswap Labs
/// @notice Maker-facing quote ladders backed by native Uniswap v4 liquidity.
/// @dev Makers express bids/asks as bounded capacity in canonical bins. The hook owns the
///      underlying v4 positions, keyed by maker-specific salts, so swaps execute through the
///      native v4 swap loop while the hook enforces quote-ladder shape and one-shot expiry.
contract NativeBookHook is BaseHook, DeltaResolver, IUnlockCallback, Ownable, ReentrancyGuardTransient, EIP712, Nonces {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;
    using StateLibrary for IPoolManager;

    uint8 public constant MIN_BINS_PER_SIDE = 1;
    uint8 public constant MAX_BINS_PER_SIDE = 32;
    uint8 public constant MAX_MAKER_BINS = 32;
    uint8 public constant MAX_RETIRE_PER_SWAP = 16;

    bytes32 private constant _SALT_NAMESPACE = keccak256("alf.native-book.salt.v1");
    bytes32 public constant BIN_CAPACITY_TYPEHASH = keccak256("BinCapacity(int8 offset,uint128 amount)");
    bytes32 public constant REPLACE_LADDER_TYPEHASH = keccak256(
        "ReplaceLadder(address maker,bytes32 poolId,BinCapacity[] bids,BinCapacity[] asks,uint40 ttl,int24 expectedRefTick,uint24 maxTickDeviation,uint256 nonce,uint256 deadline)BinCapacity(int8 offset,uint128 amount)"
    );
    bytes32 public constant CANCEL_LADDER_TYPEHASH =
        keccak256("CancelLadder(address maker,bytes32 poolId,uint256 nonce,uint256 deadline)");

    enum Side {
        Bid,
        Ask
    }

    enum UnlockAction {
        ReplaceLadder,
        CancelLadder,
        RetirePosition,
        RetirePositions,
        ClaimFees
    }

    /// @notice Pool-level parameters for canonical maker bins.
    /// @param binSpacingTicks Width of each book bin. Must be positive and aligned to the pool tick spacing.
    /// @param binsPerSide Number of canonical bid/ask bins available on each side.
    /// @param maxMakerBins Maximum active bins a single maker can maintain per pool.
    /// @param maxRetirePerSwap Maximum stale/crossed positions retired opportunistically per swap hook.
    /// @param maxQuoteTtl Maximum ladder lifetime, in seconds.
    /// @param minBinLiquidity Minimum v4 liquidity for a newly posted bin.
    struct PoolConfig {
        int24 binSpacingTicks;
        uint8 binsPerSide;
        uint8 maxMakerBins;
        uint8 maxRetirePerSwap;
        uint40 maxQuoteTtl;
        uint128 minBinLiquidity;
    }

    /// @notice Maker-supplied capacity for one canonical bin.
    /// @dev Bids use negative offsets below the reference bin. Asks use positive offsets above
    ///      the reference bin. Offset zero is reserved as the current-price gap.
    /// @param offset Canonical bin offset from the current reference bin.
    /// @param amount Maker output amount to deploy into this bin.
    struct BinCapacity {
        int8 offset;
        uint128 amount;
    }

    /// @notice Hook-owned position metadata for one maker/bin.
    /// @param maker Maker that owns this quote.
    /// @param poolId Pool this quote belongs to.
    /// @param side Bid or ask.
    /// @param tickLower Native v4 position lower tick.
    /// @param tickUpper Native v4 position upper tick.
    /// @param liquidity Native v4 liquidity currently deployed.
    /// @param expiry Unix timestamp after which the quote can be retired.
    /// @param active Whether this slot currently owns native v4 liquidity.
    struct PositionInfo {
        address maker;
        PoolId poolId;
        Side side;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint40 expiry;
        bool active;
    }

    struct ReplaceCallbackData {
        address submitter;
        address maker;
        PoolKey key;
        BinCapacity[] bids;
        BinCapacity[] asks;
        uint40 expiry;
        int24 expectedRefTick;
        uint24 maxTickDeviation;
        uint256 nonce;
        uint256 deadline;
        bool viaSignature;
    }

    struct CancelCallbackData {
        address submitter;
        address maker;
        PoolKey key;
        uint256 nonce;
        uint256 deadline;
        bool viaSignature;
    }

    struct RetireCallbackData {
        address caller;
        PoolKey key;
        bytes32 positionId;
    }

    struct RetirePositionsCallbackData {
        address caller;
        PoolKey key;
        bytes32[] positionIds;
        uint256 maxRetire;
    }

    mapping(PoolId => PoolConfig) public poolConfigs;
    mapping(PoolId => bool) public poolLive;
    mapping(bytes32 => PositionInfo) public positions;

    mapping(address => mapping(address => uint256)) private _inventory;

    mapping(bytes32 => bytes32[]) private _makerPositions;
    mapping(bytes32 => uint256) private _makerPositionIndex;

    mapping(PoolId => bytes32[]) private _activePositions;
    mapping(bytes32 => uint256) private _activePositionIndex;
    mapping(PoolId => uint256) private _retireCursor;

    event PoolCreated(
        PoolId indexed poolId,
        address indexed creator,
        address currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        uint160 sqrtPriceX96,
        int24 tick,
        PoolConfig config
    );
    event PoolLivenessUpdated(PoolId indexed poolId, address indexed updater, bool oldLive, bool newLive);
    event InventoryDeposited(
        address indexed maker,
        address indexed currency,
        address indexed depositor,
        uint256 requestedAmount,
        uint256 amount
    );
    event InventoryWithdrawn(
        address indexed maker, address indexed currency, address indexed recipient, uint256 amount
    );
    event LadderReplaced(
        PoolId indexed poolId,
        address indexed maker,
        address indexed submitter,
        uint256 bidCount,
        uint256 askCount,
        uint40 expiry,
        uint256 nonce,
        uint256 deadline,
        bool viaSignature
    );
    event LadderCanceled(
        PoolId indexed poolId,
        address indexed maker,
        address indexed submitter,
        uint256 binsRemoved,
        uint256 amount0,
        uint256 amount1,
        uint256 nonce,
        uint256 deadline,
        bool viaSignature
    );
    event BinPosted(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        Side side,
        int24 tickLower,
        int24 tickUpper,
        int8 offset,
        uint128 capacity,
        uint128 liquidity,
        uint40 expiry
    );
    event BinRetired(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        Side side,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event FeesClaimed(
        PoolId indexed poolId,
        address indexed maker,
        bytes32 indexed positionId,
        address caller,
        uint256 amount0,
        uint256 amount1
    );
    event PositionsRetired(
        PoolId indexed poolId, address indexed caller, uint256 candidateCount, uint256 maxRetire, uint256 retired
    );

    error CallbackOnlyPoolManager();
    error DirectInitializeBlocked();
    error InvalidHookAddress();
    error InvalidNativeCurrency();
    error InvalidPoolConfig();
    error InvalidBinOffset();
    error InvalidQuoteTtl();
    error InvalidBinLiquidity();
    error SignatureExpired();
    error InvalidSignature();
    error InvalidPosition();
    error InvalidMaker();
    error InvalidPayer();
    error InvalidRecipient();
    error ZeroAmount();
    error InsufficientInventory(address maker, address currency, uint256 available, uint256 required);
    error DuplicateBinOffset();
    error DuplicatePosition();
    error RefTickSlippage(int24 expectedRefTick, int24 actualRefTick, uint24 maxTickDeviation);
    error PoolNotLive(PoolId poolId);
    error PositionNotRetirable();
    error ReservedBookRange();

    /// @param _poolManager The Uniswap v4 PoolManager.
    /// @param owner_ Initial owner for pool initialization and liveness controls.
    constructor(IPoolManager _poolManager, address owner_)
        BaseHook(_poolManager)
        Ownable(owner_)
        EIP712("NativeBookHook", "1")
    {}

    /// @notice Initialize a pool and store its canonical book-bin configuration.
    /// @dev Native ETH is intentionally unsupported in this hook because maker payments are
    ///      pulled from arbitrary maker addresses during PoolManager settlement.
    /// @param key Pool key. The hook address must be this contract.
    /// @param sqrtPriceX96 Initial pool price.
    /// @param config Canonical book configuration for this pool.
    /// @return tick Initial tick returned by the PoolManager.
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, PoolConfig calldata config)
        external
        onlyOwner
        returns (int24 tick)
    {
        if (key.hooks != IHooks(address(this))) revert InvalidHookAddress();
        if (key.currency0.isAddressZero() || key.currency1.isAddressZero()) revert InvalidNativeCurrency();
        _validateConfig(key, config);

        PoolId poolId = key.toId();
        poolConfigs[poolId] = config;
        tick = poolManager.initialize(key, sqrtPriceX96);
        poolLive[poolId] = true;

        emit PoolCreated(
            poolId,
            msg.sender,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            key.tickSpacing,
            sqrtPriceX96,
            tick,
            config
        );
        emit PoolLivenessUpdated(poolId, msg.sender, false, true);
    }

    /// @notice Toggle swap liveness for a pool.
    /// @param key Pool key.
    /// @param live New liveness value.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner {
        PoolId poolId = key.toId();
        bool oldLive = poolLive[poolId];
        poolLive[poolId] = live;
        emit PoolLivenessUpdated(poolId, msg.sender, oldLive, live);
    }

    /// @notice Deposit inventory for the caller.
    /// @param currency ERC-20 currency to deposit. Native ETH is unsupported.
    /// @param amount Requested transfer amount. Fee-on-transfer tokens credit the actual received amount.
    /// @return credited Amount credited to the caller's inventory.
    function deposit(Currency currency, uint256 amount) external nonReentrant returns (uint256 credited) {
        credited = _depositFor(msg.sender, currency, amount);
    }

    /// @notice Deposit inventory for a maker.
    /// @param maker Maker receiving internal inventory credit.
    /// @param currency ERC-20 currency to deposit. Native ETH is unsupported.
    /// @param amount Requested transfer amount. Fee-on-transfer tokens credit the actual received amount.
    /// @return credited Amount credited to the maker's inventory.
    function depositFor(address maker, Currency currency, uint256 amount)
        public
        nonReentrant
        returns (uint256 credited)
    {
        credited = _depositFor(maker, currency, amount);
    }

    function _depositFor(address maker, Currency currency, uint256 amount) internal returns (uint256 credited) {
        if (maker == address(0)) revert InvalidMaker();
        if (currency.isAddressZero()) revert InvalidNativeCurrency();
        if (amount == 0) revert ZeroAmount();

        IERC20 token = IERC20(Currency.unwrap(currency));
        uint256 balanceBefore = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        credited = token.balanceOf(address(this)) - balanceBefore;
        if (credited == 0) revert ZeroAmount();

        _inventory[maker][Currency.unwrap(currency)] += credited;
        emit InventoryDeposited(maker, Currency.unwrap(currency), msg.sender, amount, credited);
    }

    /// @notice Withdraw unused maker inventory.
    /// @param currency ERC-20 currency to withdraw.
    /// @param amount Amount to withdraw from the caller's inventory.
    /// @param recipient Address receiving the ERC-20 transfer.
    function withdraw(Currency currency, uint256 amount, address recipient) external nonReentrant {
        if (currency.isAddressZero()) revert InvalidNativeCurrency();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert InvalidRecipient();

        _debitInventory(msg.sender, currency, amount);
        IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
        emit InventoryWithdrawn(msg.sender, Currency.unwrap(currency), recipient, amount);
    }

    /// @notice Return a maker's withdrawable inventory balance.
    function inventoryBalance(address maker, Currency currency) external view returns (uint256) {
        return _inventory[maker][Currency.unwrap(currency)];
    }

    /// @notice Replace the caller's whole maker ladder for a pool.
    /// @dev Existing active bins are removed and proceeds are paid to the maker before new
    ///      canonical bins are posted. New bins consume the maker's deposited inventory.
    /// @param key Pool key.
    /// @param bids Bid capacities. Offsets must be negative.
    /// @param asks Ask capacities. Offsets must be positive.
    /// @param ttl Quote lifetime in seconds, capped by the pool config.
    function replaceLadder(
        PoolKey calldata key,
        BinCapacity[] calldata bids,
        BinCapacity[] calldata asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation
    ) external nonReentrant {
        _validateLadderInput(key.toId(), bids.length, asks.length, ttl);
        _validateDistinctOffsets(bids, asks);

        uint256 nonce = _useNonce(msg.sender);
        uint40 expiry = uint40(block.timestamp) + ttl;
        poolManager.unlock(
            abi.encode(
                UnlockAction.ReplaceLadder,
                ReplaceCallbackData(
                    msg.sender, msg.sender, key, bids, asks, expiry, expectedRefTick, maxTickDeviation, nonce, 0, false
                )
            )
        );
    }

    /// @notice Replace a maker's whole ladder using an EIP-712 signature from the maker.
    /// @dev This lets solvers, market-maker daemons, or relayers post quotes without the swap router
    ///      knowing anything about book updates. New bins consume the maker's deposited inventory.
    /// @param key Pool key.
    /// @param maker Maker whose ladder is being replaced.
    /// @param bids Bid capacities. Offsets must be negative.
    /// @param asks Ask capacities. Offsets must be positive.
    /// @param ttl Quote lifetime in seconds, capped by the pool config.
    /// @param deadline Signature expiry timestamp.
    /// @param signature Maker EIP-712 signature.
    function replaceLadderWithSig(
        PoolKey calldata key,
        address maker,
        BinCapacity[] calldata bids,
        BinCapacity[] calldata asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation,
        uint256 deadline,
        bytes calldata signature
    ) external nonReentrant {
        if (block.timestamp > deadline) revert SignatureExpired();
        PoolId poolId = key.toId();
        _validateLadderInput(poolId, bids.length, asks.length, ttl);
        _validateDistinctOffsets(bids, asks);
        if (block.timestamp + ttl > deadline) revert InvalidQuoteTtl();

        uint256 nonce = _useNonce(maker);
        bytes32 digest =
            _hashReplaceLadder(key, maker, bids, asks, ttl, expectedRefTick, maxTickDeviation, nonce, deadline);
        if (!SignatureChecker.isValidSignatureNowCalldata(maker, digest, signature)) revert InvalidSignature();

        uint40 expiry = uint40(block.timestamp) + ttl;
        poolManager.unlock(
            abi.encode(
                UnlockAction.ReplaceLadder,
                ReplaceCallbackData(
                    msg.sender, maker, key, bids, asks, expiry, expectedRefTick, maxTickDeviation, nonce, deadline, true
                )
            )
        );
    }

    /// @notice Cancel all active bins for the caller in a pool and credit proceeds to caller inventory.
    /// @param key Pool key.
    function cancelLadder(PoolKey calldata key) external nonReentrant {
        uint256 nonce = _useNonce(msg.sender);
        poolManager.unlock(
            abi.encode(UnlockAction.CancelLadder, CancelCallbackData(msg.sender, msg.sender, key, nonce, 0, false))
        );
    }

    /// @notice Cancel a maker's ladder using an EIP-712 signature from the maker.
    /// @dev This lets relayers remove stale maker exposure without specialized swap-router support.
    /// @param key Pool key.
    /// @param maker Maker whose active bins should be cancelled.
    /// @param deadline Signature expiry timestamp.
    /// @param signature Maker EIP-712 signature.
    function cancelLadderWithSig(PoolKey calldata key, address maker, uint256 deadline, bytes calldata signature)
        external
        nonReentrant
    {
        if (block.timestamp > deadline) revert SignatureExpired();

        uint256 nonce = _useNonce(maker);
        bytes32 digest = _hashCancelLadder(key, maker, nonce, deadline);
        if (!SignatureChecker.isValidSignatureNowCalldata(maker, digest, signature)) revert InvalidSignature();

        poolManager.unlock(
            abi.encode(UnlockAction.CancelLadder, CancelCallbackData(msg.sender, maker, key, nonce, deadline, true))
        );
    }

    /// @notice Retire an expired or crossed position for any maker.
    /// @dev This is public so keepers can clean stale bins without the maker being online.
    /// @param key Pool key.
    /// @param positionId Position identifier emitted or read from {makerPositionAt}.
    function retirePosition(PoolKey calldata key, bytes32 positionId) external nonReentrant {
        poolManager.unlock(abi.encode(UnlockAction.RetirePosition, RetireCallbackData(msg.sender, key, positionId)));
    }

    /// @notice Claim accrued swap fees for one active maker bin without removing its liquidity.
    /// @dev Anyone can call this because proceeds are always credited to the maker recorded on the position.
    /// @param key Pool key.
    /// @param positionId Position identifier emitted or read from {makerPositionAt}.
    function claimFees(PoolKey calldata key, bytes32 positionId) external nonReentrant {
        poolManager.unlock(abi.encode(UnlockAction.ClaimFees, RetireCallbackData(msg.sender, key, positionId)));
    }

    /// @notice Retire a bounded set of expired or crossed positions.
    /// @dev Unlike {retirePosition}, this skips ids that are not currently retirable so keepers can
    ///      submit optimistic batches without a single fresh position reverting the whole batch.
    /// @param key Pool key.
    /// @param positionIds Candidate position ids.
    /// @param maxRetire Maximum positions to retire from this batch. Zero means no-op.
    /// @return retired Number of positions retired.
    function retirePositions(PoolKey calldata key, bytes32[] calldata positionIds, uint256 maxRetire)
        external
        nonReentrant
        returns (uint256 retired)
    {
        bytes memory result = poolManager.unlock(
            abi.encode(
                UnlockAction.RetirePositions, RetirePositionsCallbackData(msg.sender, key, positionIds, maxRetire)
            )
        );
        retired = abi.decode(result, (uint256));
    }

    /// @notice Return the EIP-712 digest a maker signs for {replaceLadderWithSig}.
    function hashReplaceLadder(
        PoolKey calldata key,
        address maker,
        BinCapacity[] calldata bids,
        BinCapacity[] calldata asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation,
        uint256 nonce,
        uint256 deadline
    ) external view returns (bytes32) {
        return _hashReplaceLadder(key, maker, bids, asks, ttl, expectedRefTick, maxTickDeviation, nonce, deadline);
    }

    /// @notice Return the EIP-712 digest a maker signs for {cancelLadderWithSig}.
    function hashCancelLadder(PoolKey calldata key, address maker, uint256 nonce, uint256 deadline)
        external
        view
        returns (bytes32)
    {
        return _hashCancelLadder(key, maker, nonce, deadline);
    }

    /// @notice Number of active position ids currently tracked for a maker and pool.
    function makerPositionCount(PoolId poolId, address maker) external view returns (uint256) {
        return _makerPositions[_makerKey(poolId, maker)].length;
    }

    /// @notice Return a maker's active position id at an index.
    function makerPositionAt(PoolId poolId, address maker, uint256 index) external view returns (bytes32) {
        return _makerPositions[_makerKey(poolId, maker)][index];
    }

    /// @notice Number of active position ids tracked for a pool.
    function activePositionCount(PoolId poolId) external view returns (uint256) {
        return _activePositions[poolId].length;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert CallbackOnlyPoolManager();

        UnlockAction action = abi.decode(data, (UnlockAction));
        if (action == UnlockAction.ReplaceLadder) {
            (, ReplaceCallbackData memory d) = abi.decode(data, (UnlockAction, ReplaceCallbackData));
            _replaceLadder(d);
        } else if (action == UnlockAction.CancelLadder) {
            (, CancelCallbackData memory d) = abi.decode(data, (UnlockAction, CancelCallbackData));
            (uint256 binsRemoved, uint256 amount0, uint256 amount1) =
                _removeMakerPositions(d.key, d.maker, type(uint256).max);
            emit LadderCanceled(
                d.key.toId(), d.maker, d.submitter, binsRemoved, amount0, amount1, d.nonce, d.deadline, d.viaSignature
            );
        } else if (action == UnlockAction.RetirePosition) {
            (, RetireCallbackData memory d) = abi.decode(data, (UnlockAction, RetireCallbackData));
            if (!_isRetirable(d.key, positions[d.positionId])) revert PositionNotRetirable();
            _removePosition(d.key, d.positionId);
        } else if (action == UnlockAction.RetirePositions) {
            (, RetirePositionsCallbackData memory d) = abi.decode(data, (UnlockAction, RetirePositionsCallbackData));
            uint256 retired = _retirePositions(d.key, d.positionIds, d.maxRetire);
            emit PositionsRetired(d.key.toId(), d.caller, d.positionIds.length, d.maxRetire, retired);
            return abi.encode(retired);
        } else {
            (, RetireCallbackData memory d) = abi.decode(data, (UnlockAction, RetireCallbackData));
            _claimFees(d.key, d.positionId, d.caller);
        }

        return "";
    }

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata, uint160) internal pure override returns (bytes4) {
        revert DirectInitializeBlocked();
    }

    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        PoolConfig memory config = poolConfigs[key.toId()];
        if (config.binSpacingTicks > 0 && params.tickUpper - params.tickLower == config.binSpacingTicks) {
            revert ReservedBookRange();
        }
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        if (!poolLive[poolId]) revert PoolNotLive(poolId);
        _retireSome(key, poolConfigs[poolId].maxRetirePerSwap);
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _validateLadderInput(PoolId poolId, uint256 bidCount, uint256 askCount, uint40 ttl) internal view {
        PoolConfig memory config = poolConfigs[poolId];
        if (ttl == 0 || ttl > config.maxQuoteTtl) revert InvalidQuoteTtl();
        if (bidCount + askCount > config.maxMakerBins) revert InvalidPoolConfig();
    }

    function _validateDistinctOffsets(BinCapacity[] calldata bids, BinCapacity[] calldata asks) internal pure {
        uint256 seenBids = 0;
        for (uint256 i; i < bids.length;) {
            int8 offset = bids[i].offset;
            if (offset < -32 || offset >= 0) revert InvalidBinOffset();
            uint256 bit = 1 << uint8(uint8(-offset) - 1);
            if (seenBids & bit != 0) revert DuplicateBinOffset();
            seenBids |= bit;
            unchecked {
                ++i;
            }
        }

        uint256 seenAsks = 0;
        for (uint256 i; i < asks.length;) {
            int8 offset = asks[i].offset;
            if (offset <= 0 || offset > 32) revert InvalidBinOffset();
            uint256 bit = 1 << uint8(uint8(offset) - 1);
            if (seenAsks & bit != 0) revert DuplicateBinOffset();
            seenAsks |= bit;
            unchecked {
                ++i;
            }
        }
    }

    function _hashReplaceLadder(
        PoolKey calldata key,
        address maker,
        BinCapacity[] calldata bids,
        BinCapacity[] calldata asks,
        uint40 ttl,
        int24 expectedRefTick,
        uint24 maxTickDeviation,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    REPLACE_LADDER_TYPEHASH,
                    maker,
                    key.toId(),
                    _hashBinCapacities(bids),
                    _hashBinCapacities(asks),
                    ttl,
                    expectedRefTick,
                    maxTickDeviation,
                    nonce,
                    deadline
                )
            )
        );
    }

    function _hashBinCapacities(BinCapacity[] calldata bins) internal pure returns (bytes32) {
        bytes32[] memory hashes = new bytes32[](bins.length);
        for (uint256 i; i < bins.length;) {
            hashes[i] = keccak256(abi.encode(BIN_CAPACITY_TYPEHASH, bins[i].offset, bins[i].amount));
            unchecked {
                ++i;
            }
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function _hashCancelLadder(PoolKey calldata key, address maker, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(CANCEL_LADDER_TYPEHASH, maker, key.toId(), nonce, deadline)));
    }

    function _replaceLadder(ReplaceCallbackData memory d) internal {
        PoolId poolId = d.key.toId();
        if (!poolLive[poolId]) revert PoolNotLive(poolId);
        _removeMakerPositions(d.key, d.maker, type(uint256).max);

        PoolConfig memory config = poolConfigs[poolId];
        (uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(poolId);
        int24 refTick = _referenceTick(currentTick, config.binSpacingTicks);
        _validateRefTick(refTick, d.expectedRefTick, d.maxTickDeviation);

        for (uint256 i; i < d.bids.length;) {
            _postBin(d.key, d.maker, config, refTick, sqrtPriceX96, Side.Bid, d.bids[i], d.expiry);
            unchecked {
                ++i;
            }
        }
        for (uint256 i; i < d.asks.length;) {
            _postBin(d.key, d.maker, config, refTick, sqrtPriceX96, Side.Ask, d.asks[i], d.expiry);
            unchecked {
                ++i;
            }
        }

        emit LadderReplaced(
            poolId, d.maker, d.submitter, d.bids.length, d.asks.length, d.expiry, d.nonce, d.deadline, d.viaSignature
        );
    }

    function _validateRefTick(int24 actualRefTick, int24 expectedRefTick, uint24 maxTickDeviation) internal pure {
        int256 delta = int256(actualRefTick) - int256(expectedRefTick);
        uint256 deviation = delta >= 0 ? uint256(delta) : uint256(-delta);
        if (deviation > maxTickDeviation) {
            revert RefTickSlippage(expectedRefTick, actualRefTick, maxTickDeviation);
        }
    }

    function _postBin(
        PoolKey memory key,
        address maker,
        PoolConfig memory config,
        int24 refTick,
        uint160,
        Side side,
        BinCapacity memory bin,
        uint40 expiry
    ) internal {
        if (bin.amount == 0) return;
        if (!_validOffset(side, bin.offset, config.binsPerSide)) revert InvalidBinOffset();

        int24 tickLower = refTick + int24(bin.offset) * config.binSpacingTicks;
        int24 tickUpper = tickLower + config.binSpacingTicks;
        if (tickLower < TickMath.minUsableTick(key.tickSpacing) || tickUpper > TickMath.maxUsableTick(key.tickSpacing))
        {
            revert InvalidBinOffset();
        }
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        uint128 liquidity = side == Side.Bid
            ? LiquidityAmounts.getLiquidityForAmount1(sqrtLower, sqrtUpper, bin.amount)
            : LiquidityAmounts.getLiquidityForAmount0(sqrtLower, sqrtUpper, bin.amount);
        if (liquidity < config.minBinLiquidity) revert InvalidBinLiquidity();

        bytes32 positionId = _positionId(key.toId(), maker, side, tickLower);
        bytes32 salt = _positionSalt(positionId);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: salt
            }),
            ""
        );
        _resolveDelta(key, delta, maker);

        positions[positionId] = PositionInfo({
            maker: maker,
            poolId: key.toId(),
            side: side,
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: liquidity,
            expiry: expiry,
            active: true
        });
        _trackPosition(positionId, key.toId(), maker);

        emit BinPosted(
            key.toId(), maker, positionId, side, tickLower, tickUpper, bin.offset, bin.amount, liquidity, expiry
        );
    }

    function _removeMakerPositions(PoolKey memory key, address maker, uint256 maxRemovals)
        internal
        returns (uint256 removed, uint256 amount0, uint256 amount1)
    {
        bytes32 makerKey = _makerKey(key.toId(), maker);
        while (_makerPositions[makerKey].length != 0 && removed < maxRemovals) {
            bytes32 positionId = _makerPositions[makerKey][_makerPositions[makerKey].length - 1];
            (uint256 removedAmount0, uint256 removedAmount1, bool didRemove) = _removePosition(key, positionId);
            amount0 += removedAmount0;
            amount1 += removedAmount1;
            if (!didRemove) break;
            unchecked {
                ++removed;
            }
        }
    }

    function _removePosition(PoolKey memory key, bytes32 positionId)
        internal
        returns (uint256 amount0, uint256 amount1, bool removed)
    {
        PositionInfo memory p = positions[positionId];
        if (!p.active) return (0, 0, false);

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                liquidityDelta: -int256(uint256(p.liquidity)),
                salt: _positionSalt(positionId)
            }),
            ""
        );
        (amount0, amount1) = _resolveDelta(key, delta, p.maker);

        delete positions[positionId];
        _untrackPosition(positionId, p.poolId, p.maker);
        emit BinRetired(p.poolId, p.maker, positionId, p.side, p.tickLower, p.tickUpper, p.liquidity, amount0, amount1);
        removed = true;
    }

    function _retirePositions(PoolKey memory key, bytes32[] memory positionIds, uint256 maxRetire)
        internal
        returns (uint256 retired)
    {
        for (uint256 i; i < positionIds.length && retired < maxRetire;) {
            bytes32 positionId = positionIds[i];
            if (_isRetirable(key, positions[positionId])) {
                _removePosition(key, positionId);
                unchecked {
                    ++retired;
                }
            }
            unchecked {
                ++i;
            }
        }
    }

    function _claimFees(PoolKey memory key, bytes32 positionId, address caller) internal {
        PositionInfo memory p = positions[positionId];
        if (!p.active || PoolId.unwrap(p.poolId) != PoolId.unwrap(key.toId())) revert InvalidPosition();

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: p.tickLower, tickUpper: p.tickUpper, liquidityDelta: 0, salt: _positionSalt(positionId)
            }),
            ""
        );
        (uint256 amount0, uint256 amount1) = _resolveDelta(key, delta, p.maker);
        emit FeesClaimed(p.poolId, p.maker, positionId, caller, amount0, amount1);
    }

    function _retireSome(PoolKey calldata key, uint8 maxRemovals) internal {
        if (maxRemovals == 0) return;
        PoolId poolId = key.toId();
        bytes32[] storage ids = _activePositions[poolId];
        if (ids.length == 0) return;

        uint256 checked = 0;
        uint256 removed = 0;
        uint256 cursor = _retireCursor[poolId] % ids.length;
        while (ids.length != 0 && checked < maxRemovals && removed < maxRemovals) {
            if (cursor >= ids.length) cursor = 0;
            bytes32 positionId = ids[cursor];
            unchecked {
                ++checked;
            }
            if (_isRetirable(key, positions[positionId])) {
                _removePosition(key, positionId);
                unchecked {
                    ++removed;
                }
                if (cursor >= ids.length) cursor = 0;
            } else {
                unchecked {
                    ++cursor;
                }
            }
        }
        _retireCursor[poolId] = ids.length == 0 ? 0 : cursor % ids.length;
    }

    function _isRetirable(PoolKey memory key, PositionInfo memory p) internal view returns (bool) {
        if (!p.active || PoolId.unwrap(p.poolId) != PoolId.unwrap(key.toId())) return false;
        if (block.timestamp >= p.expiry) return true;
        (, int24 currentTick,,) = poolManager.getSlot0(p.poolId);
        if (p.side == Side.Ask) return currentTick >= p.tickUpper;
        return currentTick < p.tickLower;
    }

    function _resolveDelta(PoolKey memory key, BalanceDelta delta, address maker)
        internal
        returns (uint256 credit0, uint256 credit1)
    {
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        if (amount0 < 0) _debitAndSettle(key.currency0, maker, uint256(uint128(-amount0)));
        else if (amount0 > 0) credit0 = _takeAndCredit(key.currency0, maker, uint256(uint128(amount0)));

        if (amount1 < 0) _debitAndSettle(key.currency1, maker, uint256(uint128(-amount1)));
        else if (amount1 > 0) credit1 = _takeAndCredit(key.currency1, maker, uint256(uint128(amount1)));
    }

    function _debitAndSettle(Currency currency, address maker, uint256 amount) internal {
        _debitInventory(maker, currency, amount);
        _settle(currency, address(this), amount);
    }

    function _takeAndCredit(Currency currency, address maker, uint256 amount) internal returns (uint256 credited) {
        uint256 balanceBefore = currency.balanceOfSelf();
        _take(currency, address(this), amount);
        credited = currency.balanceOfSelf() - balanceBefore;
        _inventory[maker][Currency.unwrap(currency)] += credited;
    }

    function _debitInventory(address maker, Currency currency, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        uint256 available = _inventory[maker][token];
        if (available < amount) revert InsufficientInventory(maker, token, available, amount);
        unchecked {
            _inventory[maker][token] = available - amount;
        }
    }

    function _validateConfig(PoolKey calldata key, PoolConfig calldata config) internal pure {
        if (
            config.binSpacingTicks <= 0 || config.binSpacingTicks % key.tickSpacing != 0
                || config.binsPerSide < MIN_BINS_PER_SIDE || config.binsPerSide > MAX_BINS_PER_SIDE
                || config.maxMakerBins == 0 || config.maxMakerBins > MAX_MAKER_BINS
                || config.maxRetirePerSwap > MAX_RETIRE_PER_SWAP || config.maxQuoteTtl == 0
                || config.minBinLiquidity == 0
        ) {
            revert InvalidPoolConfig();
        }
    }

    function _validOffset(Side side, int8 offset, uint8 binsPerSide) internal pure returns (bool) {
        if (side == Side.Bid) return offset < 0 && offset >= -int8(binsPerSide);
        return offset > 0 && offset <= int8(binsPerSide);
    }

    function _referenceTick(int24 currentTick, int24 binSpacing) internal pure returns (int24 refTick) {
        int24 compressed = currentTick / binSpacing;
        if (currentTick < 0 && currentTick % binSpacing != 0) compressed--;
        refTick = compressed * binSpacing;
    }

    function _positionId(PoolId poolId, address maker, Side side, int24 tickLower) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, maker, side, tickLower));
    }

    function _positionSalt(bytes32 positionId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_SALT_NAMESPACE, positionId));
    }

    function _makerKey(PoolId poolId, address maker) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, maker));
    }

    function _trackPosition(bytes32 positionId, PoolId poolId, address maker) internal {
        if (_makerPositionIndex[positionId] != 0 || _activePositionIndex[positionId] != 0) {
            revert DuplicatePosition();
        }
        bytes32 makerKey = _makerKey(poolId, maker);
        _makerPositionIndex[positionId] = _makerPositions[makerKey].length + 1;
        _makerPositions[makerKey].push(positionId);
        _activePositionIndex[positionId] = _activePositions[poolId].length + 1;
        _activePositions[poolId].push(positionId);
    }

    function _untrackPosition(bytes32 positionId, PoolId poolId, address maker) internal {
        bytes32 makerKey = _makerKey(poolId, maker);
        _removeTracked(_makerPositions[makerKey], _makerPositionIndex, positionId);
        _removeTracked(_activePositions[poolId], _activePositionIndex, positionId);
    }

    function _removeTracked(bytes32[] storage ids, mapping(bytes32 => uint256) storage indexOf, bytes32 id) internal {
        uint256 indexPlusOne = indexOf[id];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = ids.length - 1;
        if (index != lastIndex) {
            bytes32 last = ids[lastIndex];
            ids[index] = last;
            indexOf[last] = indexPlusOne;
        }
        ids.pop();
        delete indexOf[id];
    }

    /// @inheritdoc DeltaResolver
    function _pay(Currency token, address payer, uint256 amount) internal override {
        if (payer != address(this)) revert InvalidPayer();
        token.transfer(address(poolManager), amount);
    }
}
