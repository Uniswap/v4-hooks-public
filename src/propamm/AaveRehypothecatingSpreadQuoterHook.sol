// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {SpreadQuoterBase} from "./base/SpreadQuoterBase.sol";
import {IPropAMMIndex} from "./interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";

/// @title AaveRehypothecatingSpreadQuoterHook
/// @notice Spread quoter that self-manages persistent v4 LP at single-tick concentration
///         and rehypothecates idle inventory into Aave V3 for yield. Pricing is via fee
///         overrides using SwapSimulator (inherited from SpreadQuoterBase). Tokens not
///         deployed as LP are deposited to Aave; withdrawn on-demand when needed for
///         LP operations or owner withdrawals.
///
///         Total idle inventory = ERC-20 balance + ERC-6909 claims + aToken balance.
///         LP in pool is separate (managed via deployLiquidity/removeLiquidity).
contract AaveRehypothecatingSpreadQuoterHook is SpreadQuoterBase, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 internal constant MAX_PIPS = 1_000_000;

    // ──── Unlock Action Dispatch ────

    enum UnlockAction {
        DEPLOY,
        REMOVE,
        REPOSITION,
        REDEEM_CLAIMS
    }

    // ──── LP State ────

    struct ActivePosition {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    bytes32 public constant LP_SALT = bytes32(uint256(0x41415645)); // "AAVE"

    mapping(PoolId => ActivePosition) public activePosition;

    // ──── Aave State ────

    IAavePool public immutable aavePool;
    uint24 public targetUtilizationPips;
    uint24 public rebalanceThresholdPips;
    mapping(address => address) public aTokenFor;

    // ──── Events ────

    event LiquidityDeployed(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint128 liquidity);
    event LiquidityRemoved(PoolId indexed poolId);
    event LiquidityRepositioned(PoolId indexed poolId, int24 newTickLower, int24 newTickUpper, uint128 liquidity);
    event Deposit(Currency indexed token, uint256 amount);
    event Withdrawal(Currency indexed token, uint256 amount);
    event AaveTokenConfigured(address indexed underlying, address indexed aToken);
    event AaveSupply(address indexed underlying, uint256 amount);
    event AaveWithdraw(address indexed underlying, uint256 amount);
    event TargetUtilizationUpdated(uint24 targetUtilizationPips);
    event RebalanceThresholdUpdated(uint24 rebalanceThresholdPips);

    // ──── Errors ────

    error LiquidityNotAllowed();
    error NoActivePosition();
    error PositionAlreadyActive();
    error InsufficientInventory();
    error AaveTokenNotConfigured();

    // ──── Constructor ────

    constructor(
        IPoolManager _poolManager,
        IPropAMMIndex _index,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_,
        IAavePool _aavePool,
        uint24 _targetUtilizationPips,
        uint24 _rebalanceThresholdPips
    ) SpreadQuoterBase(_poolManager, _index, _attestationRegistry, maxGas_, owner_, "AaveRehypothecatingSpreadQuoterHook") {
        aavePool = _aavePool;
        targetUtilizationPips = _targetUtilizationPips;
        rebalanceThresholdPips = _rebalanceThresholdPips;
    }

    // ──── Hook Permissions ────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterAddLiquidity: false,
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

    // ──── Hook Lifecycle: Block External LP ────

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    // ──── LP Management (Owner) ────

    /// @notice Deploy LP at the active tick with the specified liquidity.
    function deployLiquidity(PoolKey calldata key, uint128 liquidity) external onlyOwner {
        PoolId poolId = key.toId();
        if (activePosition[poolId].liquidity > 0) revert PositionAlreadyActive();

        poolManager.unlock(abi.encode(UnlockAction.DEPLOY, abi.encode(key, liquidity)));

        _lazyRebalance(key.currency0);
        _lazyRebalance(key.currency1);
    }

    /// @notice Remove all LP for a pool.
    function removeLiquidity(PoolKey calldata key) external onlyOwner {
        PoolId poolId = key.toId();
        if (activePosition[poolId].liquidity == 0) revert NoActivePosition();

        poolManager.unlock(abi.encode(UnlockAction.REMOVE, abi.encode(key)));

        _lazyRebalance(key.currency0);
        _lazyRebalance(key.currency1);
    }

    /// @notice Set the active tick. If LP exists, repositions it to the new tick.
    function setActiveTick(PoolKey calldata key, int24 newActiveLowerTick) external override onlyOwner {
        if (newActiveLowerTick % key.tickSpacing != 0) revert InvalidTickRange();

        PoolId poolId = key.toId();
        if (activePosition[poolId].liquidity > 0) {
            poolManager.unlock(abi.encode(UnlockAction.REPOSITION, abi.encode(key, newActiveLowerTick)));

            _lazyRebalance(key.currency0);
            _lazyRebalance(key.currency1);
        } else {
            activeLowerTick[poolId] = newActiveLowerTick;
            emit ActiveTickUpdated(poolId, newActiveLowerTick);
        }
    }

    // ──── Unlock Callback ────

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));

        (UnlockAction action, bytes memory payload) = abi.decode(data, (UnlockAction, bytes));

        if (action == UnlockAction.DEPLOY) {
            (PoolKey memory key, uint128 liquidity) = abi.decode(payload, (PoolKey, uint128));
            _executeDeploy(key, liquidity);
        } else if (action == UnlockAction.REMOVE) {
            PoolKey memory key = abi.decode(payload, (PoolKey));
            _executeRemove(key);
        } else if (action == UnlockAction.REPOSITION) {
            (PoolKey memory key, int24 newTick) = abi.decode(payload, (PoolKey, int24));
            _executeReposition(key, newTick);
        } else if (action == UnlockAction.REDEEM_CLAIMS) {
            (Currency currency, uint256 amount) = abi.decode(payload, (Currency, uint256));
            poolManager.burn(address(this), currency.toId(), amount);
            poolManager.take(currency, address(this), amount);
        }

        return "";
    }

    // ──── Internal: LP Execution ────

    function _executeDeploy(PoolKey memory key, uint128 liquidity) internal {
        PoolId poolId = key.toId();
        int24 tickLower = activeLowerTick[poolId];
        int24 tickUpper = tickLower + key.tickSpacing;

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: LP_SALT
            }),
            ""
        );

        _settleDeployDelta(key, delta);
        activePosition[poolId] = ActivePosition(tickLower, tickUpper, liquidity);

        emit LiquidityDeployed(poolId, tickLower, tickUpper, liquidity);
    }

    function _executeRemove(PoolKey memory key) internal {
        PoolId poolId = key.toId();
        ActivePosition memory pos = activePosition[poolId];

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidityDelta: -int256(uint256(pos.liquidity)),
                salt: LP_SALT
            }),
            ""
        );

        _settleRemoveDelta(key, delta);
        delete activePosition[poolId];

        emit LiquidityRemoved(poolId);
    }

    function _executeReposition(PoolKey memory key, int24 newTick) internal {
        PoolId poolId = key.toId();
        ActivePosition memory oldPos = activePosition[poolId];

        // Remove old LP
        BalanceDelta removeDelta;
        if (oldPos.liquidity > 0) {
            (removeDelta,) = poolManager.modifyLiquidity(
                key,
                ModifyLiquidityParams({
                    tickLower: oldPos.tickLower,
                    tickUpper: oldPos.tickUpper,
                    liquidityDelta: -int256(uint256(oldPos.liquidity)),
                    salt: LP_SALT
                }),
                ""
            );
        }

        // Update tick
        int24 newTickUpper = newTick + key.tickSpacing;
        activeLowerTick[poolId] = newTick;
        emit ActiveTickUpdated(poolId, newTick);

        // Add new LP
        (BalanceDelta addDelta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: newTick,
                tickUpper: newTickUpper,
                liquidityDelta: int256(uint256(oldPos.liquidity)),
                salt: LP_SALT
            }),
            ""
        );

        // Net settle
        _settleNetDelta(key, removeDelta, addDelta);
        activePosition[poolId] = ActivePosition(newTick, newTickUpper, oldPos.liquidity);

        emit LiquidityRepositioned(poolId, newTick, newTickUpper, oldPos.liquidity);
    }

    // ──── Internal: Settlement ────

    function _settleDeployDelta(PoolKey memory key, BalanceDelta delta) internal {
        // Deploy: hook owes tokens to pool (negative delta means tokens owed)
        _settleOrTake(key.currency0, delta.amount0());
        _settleOrTake(key.currency1, delta.amount1());
    }

    function _settleRemoveDelta(PoolKey memory key, BalanceDelta delta) internal {
        // Remove: pool owes tokens to hook (positive delta means tokens received)
        _settleOrTake(key.currency0, delta.amount0());
        _settleOrTake(key.currency1, delta.amount1());
    }

    function _settleNetDelta(PoolKey memory key, BalanceDelta removeDelta, BalanceDelta addDelta) internal {
        _settleOrTake(key.currency0, removeDelta.amount0() + addDelta.amount0());
        _settleOrTake(key.currency1, removeDelta.amount1() + addDelta.amount1());
    }

    /// @dev Settle (pay) or take (receive) based on the sign of net.
    ///      Negative = hook owes pool → settle (ensure ERC-20 available, withdraw from Aave if needed).
    ///      Positive = pool owes hook → take as ERC-20.
    function _settleOrTake(Currency currency, int128 net) internal {
        if (net < 0) {
            uint256 amount = uint256(int256(-net));
            _ensureErc20(currency, amount);
            _settle(currency, address(this), amount);
        } else if (net > 0) {
            _take(currency, address(this), uint256(int256(net)));
        }
    }

    /// @dev Ensure we have enough ERC-20 to settle. Withdraws from Aave if needed.
    function _ensureErc20(Currency currency, uint256 amount) internal {
        address underlying = Currency.unwrap(currency);
        uint256 erc20Bal = IERC20Minimal(underlying).balanceOf(address(this));
        if (erc20Bal >= amount) return;

        uint256 shortfall = amount - erc20Bal;
        if (aTokenFor[underlying] == address(0)) revert InsufficientInventory();

        uint256 aTokenBal = IERC20Minimal(aTokenFor[underlying]).balanceOf(address(this));
        if (aTokenBal < shortfall) revert InsufficientInventory();

        _aaveWithdraw(currency, shortfall);
    }

    // ──── Aave Operations ────

    function _aaveWithdraw(Currency currency, uint256 amount) internal {
        address underlying = Currency.unwrap(currency);
        aavePool.withdraw(underlying, amount, address(this));
        emit AaveWithdraw(underlying, amount);
    }

    function _aaveSupply(Currency currency, uint256 amount) internal {
        address underlying = Currency.unwrap(currency);
        aavePool.supply(underlying, amount, address(this), 0);
        emit AaveSupply(underlying, amount);
    }

    /// @dev Lazy rebalance: if the hook holds excess ERC-20, deposit to Aave.
    ///      Only deposits, never proactively withdraws.
    function _lazyRebalance(Currency currency) internal {
        address underlying = Currency.unwrap(currency);
        if (aTokenFor[underlying] == address(0)) return;

        uint256 erc20Bal = IERC20Minimal(underlying).balanceOf(address(this));
        uint256 aTokenBal = IERC20Minimal(aTokenFor[underlying]).balanceOf(address(this));
        uint256 total = erc20Bal + aTokenBal;
        if (total == 0) return;

        uint256 idealAave = total * targetUtilizationPips / MAX_PIPS;
        if (aTokenBal >= idealAave) return;

        uint256 drift = idealAave - aTokenBal;
        if (drift * MAX_PIPS <= total * rebalanceThresholdPips) return;

        uint256 toDeposit = drift;
        if (toDeposit > erc20Bal) toDeposit = erc20Bal;
        if (toDeposit > 0) {
            _aaveSupply(currency, toDeposit);
        }
    }

    // ──── Internal: Helpers ────

    function _totalInventory(Currency currency) internal view returns (uint256) {
        address underlying = Currency.unwrap(currency);
        uint256 erc20Bal = IERC20Minimal(underlying).balanceOf(address(this));
        uint256 claimBal = poolManager.balanceOf(address(this), currency.toId());
        uint256 aTokenBal;
        if (aTokenFor[underlying] != address(0)) {
            aTokenBal = IERC20Minimal(aTokenFor[underlying]).balanceOf(address(this));
        }
        return erc20Bal + claimBal + aTokenBal;
    }

    function _aTokenBalance(Currency currency) internal view returns (uint256) {
        address underlying = Currency.unwrap(currency);
        address aToken = aTokenFor[underlying];
        if (aToken == address(0)) return 0;
        return IERC20Minimal(aToken).balanceOf(address(this));
    }

    // ──── Inventory Management (Owner) ────

    /// @notice Deposit ERC-20 tokens into the hook's inventory.
    function deposit(Currency token, uint256 amount) external onlyOwner {
        IERC20Minimal(Currency.unwrap(token)).transferFrom(msg.sender, address(this), amount);
        emit Deposit(token, amount);
    }

    /// @notice Withdraw tokens. Redeems from Aave and/or claims if ERC-20 is insufficient.
    function withdraw(Currency token, uint256 amount) external onlyOwner {
        address underlying = Currency.unwrap(token);
        uint256 erc20Bal = IERC20Minimal(underlying).balanceOf(address(this));
        if (erc20Bal < amount) {
            uint256 shortfall = amount - erc20Bal;
            uint256 aTokenBal = _aTokenBalance(token);
            if (aTokenBal > 0) {
                uint256 fromAave = shortfall > aTokenBal ? aTokenBal : shortfall;
                _aaveWithdraw(token, fromAave);
                shortfall -= fromAave;
            }
            if (shortfall > 0) {
                poolManager.unlock(abi.encode(UnlockAction.REDEEM_CLAIMS, abi.encode(token, shortfall)));
            }
        }
        IERC20Minimal(underlying).transfer(msg.sender, amount);
        emit Withdrawal(token, amount);
    }

    /// @notice Convert ERC-6909 claims to ERC-20 tokens.
    function redeemClaims(Currency currency, uint256 amount) external onlyOwner {
        poolManager.unlock(abi.encode(UnlockAction.REDEEM_CLAIMS, abi.encode(currency, amount)));
    }

    // ──── View Functions ────

    /// @notice Total idle inventory (ERC-20 + claims + aTokens). Excludes LP in pool.
    function totalInventory(Currency currency) external view returns (uint256) {
        return _totalInventory(currency);
    }

    /// @notice View the hook's ERC-6909 claim balance for a given currency.
    function claimBalance(Currency currency) external view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    /// @notice Current Aave utilization for a currency (ppm).
    function currentUtilization(Currency currency) external view returns (uint256 utilizationPips) {
        address underlying = Currency.unwrap(currency);
        uint256 erc20Bal = IERC20Minimal(underlying).balanceOf(address(this));
        uint256 aTokenBal = _aTokenBalance(currency);
        uint256 total = erc20Bal + aTokenBal;
        if (total == 0) return 0;
        return aTokenBal * MAX_PIPS / total;
    }

    // ──── Owner Configuration ────

    /// @notice Configure an aToken for a currency and approve Aave to spend it.
    function configureAaveToken(address underlying, address aToken) external onlyOwner {
        aTokenFor[underlying] = aToken;
        IERC20Minimal(underlying).approve(address(aavePool), type(uint256).max);
        emit AaveTokenConfigured(underlying, aToken);
    }

    function setTargetUtilization(uint24 _targetUtilizationPips) external onlyOwner {
        targetUtilizationPips = _targetUtilizationPips;
        emit TargetUtilizationUpdated(_targetUtilizationPips);
    }

    function setRebalanceThreshold(uint24 _rebalanceThresholdPips) external onlyOwner {
        rebalanceThresholdPips = _rebalanceThresholdPips;
        emit RebalanceThresholdUpdated(_rebalanceThresholdPips);
    }
}
