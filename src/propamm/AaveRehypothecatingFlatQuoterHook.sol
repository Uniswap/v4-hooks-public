// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IPropAMMIndex} from "./interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry, Attestation} from "./interfaces/IAttestationRegistry.sol";
import {QuoterHookData} from "./interfaces/IQuoterHook.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {FlatQuoterBase} from "./base/FlatQuoterBase.sol";

/// @title AaveRehypothecatingFlatQuoterHook
/// @notice Flat-price quoter that rehypothecates idle inventory into Aave V3 for yield.
///         Executes swaps at fixed bid/ask coefficients (like FlatLevelQuoterHook) and
///         lazily rebalances between local ERC-20 and Aave on each swap. Withdraws from
///         Aave on-demand when local liquidity is insufficient for settlement.
///
///         Total inventory = ERC-20 balance + ERC-6909 claims + aToken balance.
///         Target utilization is configurable (e.g., 80% in Aave, 20% local buffer).
contract AaveRehypothecatingFlatQuoterHook is FlatQuoterBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    uint256 internal constant MAX_PIPS = 1_000_000;

    // ──── State ────

    IAavePool public immutable aavePool;
    uint24 public targetUtilizationPips; // fraction of total to keep in Aave (ppm)
    uint24 public rebalanceThresholdPips; // min drift before triggering Aave ops (ppm)
    mapping(address => address) public aTokenFor; // underlying → aToken

    // ──── Events ────

    event AaveTokenConfigured(address indexed underlying, address indexed aToken);
    event AaveSupply(address indexed underlying, uint256 amount);
    event AaveWithdraw(address indexed underlying, uint256 amount);
    event TargetUtilizationUpdated(uint24 targetUtilizationPips);
    event RebalanceThresholdUpdated(uint24 rebalanceThresholdPips);

    // ──── Errors ────

    error AaveTokenNotConfigured();

    constructor(
        IPoolManager _poolManager,
        IPropAMMIndex _index,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_,
        IAavePool _aavePool,
        uint24 _targetUtilizationPips,
        uint24 _rebalanceThresholdPips
    ) FlatQuoterBase(_poolManager, _index, _attestationRegistry, maxGas_, owner_, "AaveRehypothecatingFlatQuoterHook", "1") {
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
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──── IQuoterHook: Inventory-Aware Quoting ────

    /// @notice Inventory-aware indicative quote. Caps output at total inventory
    ///         (ERC-20 + ERC-6909 claims + aTokens) to avoid winning auctions we can't fill.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        override
        returns (uint256 outputAmount)
    {
        FlatPricingState memory state = flatPricingState[key.toId()];
        bool isAttested;
        address attester;

        if (hookData.length > 0) {
            QuoterHookData memory hd = abi.decode(hookData, (QuoterHookData));
            if (hd.curveUpdateData.length > 0) {
                (FlatPricingState memory newState,,,) =
                    abi.decode(hd.curveUpdateData, (FlatPricingState, PoolId, uint256, bytes));
                state = newState;
            }
            if (hd.attestationData.length > 0) {
                (Attestation memory att, bool valid) = attestationRegistry.verify(hd.attestationData);
                isAttested = valid;
                attester = valid ? att.attester : address(0);
            }
        }

        outputAmount = _priceWithState(zeroForOne, amountSpecified, isAttested, attester, state);
        if (outputAmount == 0) return 0;

        // Cap at total inventory for the output currency
        Currency outputCurrency = zeroForOne ? key.currency1 : key.currency0;
        uint256 inventory = _totalInventory(outputCurrency);
        if (outputAmount > inventory) {
            if (amountSpecified < 0) {
                // Exact input: cap output at inventory
                outputAmount = inventory;
            } else {
                // Exact output: can't fill → skip
                return 0;
            }
        }
    }

    // ──── Core Swap Logic ────

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // 1. Apply curve update if present
        if (hookData.length > 0) {
            QuoterHookData memory hd = abi.decode(hookData, (QuoterHookData));
            if (hd.curveUpdateData.length > 0) {
                _applyCurveUpdate(key.toId(), hd.curveUpdateData);
            }
        }

        // 2. Load pricing state, compute amounts
        FlatPricingState memory state = flatPricingState[key.toId()];
        if (!state.live) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool isExactInput = params.amountSpecified < 0;
        uint256 absAmount = isExactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint128 coefficient = params.zeroForOne ? state.bidCoefficient : state.askCoefficient;

        uint256 inputAmount;
        uint256 outputAmount;
        if (isExactInput) {
            inputAmount = absAmount;
            outputAmount = (absAmount * coefficient) / 1e18;
        } else {
            outputAmount = absAmount;
            inputAmount = (absAmount * 1e18 + coefficient - 1) / coefficient;
        }

        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // 3. Ensure sufficient local liquidity for output
        _ensureLocalLiquidity(outputCurrency, outputAmount);

        // 4. Settle output to PM (burn claims first, then ERC-20)
        _settleOutput(outputCurrency, outputAmount);

        // 5. Mint input as ERC-6909 claims
        poolManager.mint(address(this), inputCurrency.toId(), inputAmount);

        // 6. Lazy rebalance: deposit excess ERC-20 to Aave
        _lazyRebalance(inputCurrency);

        // 7. Return BeforeSwapDelta
        return (IHooks.beforeSwap.selector, _buildBeforeSwapDelta(params, inputAmount, outputAmount), 0);
    }

    // ──── Internal: Aave Operations ────

    /// @dev Ensure the hook has enough ERC-20 + claims locally to settle `amount`.
    ///      Withdraws from Aave if local liquidity is insufficient.
    function _ensureLocalLiquidity(Currency currency, uint256 amount) internal {
        address underlying = Currency.unwrap(currency);
        uint256 erc20Bal = IERC20Minimal(underlying).balanceOf(address(this));
        uint256 claimBal = poolManager.balanceOf(address(this), currency.toId());
        uint256 localTotal = erc20Bal + claimBal;

        if (localTotal < amount) {
            uint256 shortfall = amount - localTotal;
            if (aTokenFor[underlying] == address(0)) revert InsufficientInventory();
            uint256 aTokenBal = IERC20Minimal(aTokenFor[underlying]).balanceOf(address(this));
            if (localTotal + aTokenBal < amount) revert InsufficientInventory();
            _aaveWithdraw(currency, shortfall);
        }
    }

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

    /// @dev Lazy rebalance: if the hook holds excess ERC-20 for this currency,
    ///      deposit the excess to Aave. Only deposits, never proactively withdraws.
    function _lazyRebalance(Currency currency) internal {
        address underlying = Currency.unwrap(currency);
        if (aTokenFor[underlying] == address(0)) return;

        uint256 erc20Bal = IERC20Minimal(underlying).balanceOf(address(this));
        uint256 aTokenBal = IERC20Minimal(aTokenFor[underlying]).balanceOf(address(this));
        uint256 total = erc20Bal + aTokenBal;
        if (total == 0) return;

        uint256 idealAave = total * targetUtilizationPips / MAX_PIPS;

        if (aTokenBal >= idealAave) return; // already at or above target

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

    /// @notice Withdraw tokens. Redeems from Aave and/or claims if ERC-20 is insufficient.
    function withdraw(Currency token, uint256 amount) external override onlyOwner {
        address underlying = Currency.unwrap(token);
        uint256 erc20Bal = IERC20Minimal(underlying).balanceOf(address(this));
        if (erc20Bal < amount) {
            uint256 shortfall = amount - erc20Bal;
            // Try Aave first
            uint256 aTokenBal = _aTokenBalance(token);
            if (aTokenBal > 0) {
                uint256 fromAave = shortfall > aTokenBal ? aTokenBal : shortfall;
                _aaveWithdraw(token, fromAave);
                shortfall -= fromAave;
            }
            // Redeem remaining from claims
            if (shortfall > 0) {
                poolManager.unlock(abi.encode(token, shortfall));
            }
        }
        IERC20Minimal(underlying).transfer(msg.sender, amount);
        emit Withdrawal(token, amount);
    }

    // ──── View Functions ────

    /// @notice Total inventory across ERC-20, ERC-6909 claims, and aTokens.
    function totalInventory(Currency currency) external view returns (uint256) {
        return _totalInventory(currency);
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
