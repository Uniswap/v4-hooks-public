// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IAttestationRegistry} from "./interfaces/IAttestationRegistry.sol";
import {FlatQuoterBase} from "./base/FlatQuoterBase.sol";

/// @title FlatLevelQuoterHook
/// @notice Flat-price quoter with delta override settlement and ERC-20 inventory.
///         Executes swaps at fixed coefficients (bid/ask) without using v4's AMM math.
///         The hook holds ERC-20 tokens deposited by the maker. Capacity = token balance.
///         Supports signed pricing updates via hookData with one-update-per-block enforcement.
contract FlatLevelQuoterHook is FlatQuoterBase {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    constructor(
        IPoolManager _poolManager,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_
    ) FlatQuoterBase(_poolManager, _attestationRegistry, maxGas_, owner_, "FlatLevelQuoterHook", "1") {}

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

    // ──── Core Swap Logic ────

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        {
            (bytes memory curveUpdateData,,) = _resolveHookData(hookData);
            if (curveUpdateData.length > 0) {
                _applyCurveUpdate(key.toId(), curveUpdateData);
            }
        }

        FlatPricingState memory state = flatPricingState[key.toId()];
        if (!state.live) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        PoolId poolId = key.toId();
        bool isExactInput = params.amountSpecified < 0;
        uint256 absAmount = isExactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint128 coefficient = params.zeroForOne ? state.bidCoefficient : state.askCoefficient;

        uint256 inputAmount;
        uint256 outputAmount;
        if (isExactInput) {
            inputAmount = absAmount;
            outputAmount = _computeOutput(poolId, params.zeroForOne, absAmount, coefficient);
        } else {
            outputAmount = absAmount;
            inputAmount = _computeInput(poolId, params.zeroForOne, absAmount, coefficient);
        }

        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Check inventory: ERC-20 balance + ERC-6909 claims
        uint256 erc20Bal = IERC20Minimal(Currency.unwrap(outputCurrency)).balanceOf(address(this));
        uint256 claimBal = poolManager.balanceOf(address(this), outputCurrency.toId());
        if (erc20Bal + claimBal < outputAmount) revert InsufficientInventory();

        _settleWithClaimPriority(outputCurrency, outputAmount);
        poolManager.mint(address(this), inputCurrency.toId(), inputAmount);

        BeforeSwapDelta bsd;
        if (isExactInput) {
            bsd = toBeforeSwapDelta(int128(uint128(inputAmount)), -int128(uint128(outputAmount)));
        } else {
            bsd = toBeforeSwapDelta(-int128(uint128(outputAmount)), int128(uint128(inputAmount)));
        }
        return (IHooks.beforeSwap.selector, bsd, 0);
    }
}
