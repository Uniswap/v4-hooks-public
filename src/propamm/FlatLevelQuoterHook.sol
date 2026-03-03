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
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {BasePropAMMHook} from "./base/BasePropAMMHook.sol";
import {IPropAMMIndex, QuoterType} from "./interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry, Attestation} from "./interfaces/IAttestationRegistry.sol";
import {QuoterHookData} from "./interfaces/IQuoterHook.sol";

/// @title FlatLevelQuoterHook
/// @notice Flat-price quoter with delta override settlement and ERC-20 inventory.
///         Executes swaps at fixed coefficients (bid/ask) without using v4's AMM math.
///         The hook holds ERC-20 tokens deposited by the maker. Capacity = token balance.
///         Supports signed pricing updates via hookData with one-update-per-block enforcement.
contract FlatLevelQuoterHook is BasePropAMMHook, EIP712, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct FlatPricingState {
        uint128 bidCoefficient; // Price coefficient for zeroForOne, 1e18-scaled
        uint128 askCoefficient; // Price coefficient for oneForZero, 1e18-scaled
        uint16 attestedDiscountBps; // Discount for attested flow in indicative quotes (bps)
        bool live;
    }

    bytes32 private constant FLAT_PRICING_UPDATE_TYPEHASH = keccak256(
        "FlatPricingUpdate(uint128 bidCoefficient,uint128 askCoefficient,uint16 attestedDiscountBps,bool live,bytes32 poolId,uint256 deadline)"
    );

    mapping(PoolId => FlatPricingState) public flatPricingState;
    mapping(PoolId => mapping(uint256 => bytes32)) internal blockUpdateHash;
    address public priceSigner;

    event FlatPricingStateUpdated(PoolId indexed poolId, FlatPricingState state);
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);
    event PriceSignerUpdated(address indexed newSigner);
    event Deposit(Currency indexed token, uint256 amount);
    event Withdrawal(Currency indexed token, uint256 amount);

    error LiquidityNotAllowed();
    error InsufficientInventory();
    error ExpiredUpdate();
    error PoolMismatch();
    error ConflictingCurveUpdate();
    error InvalidPriceSigner();

    constructor(
        IPoolManager _poolManager,
        IPropAMMIndex _index,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_,
        address owner_
    )
        BasePropAMMHook(_poolManager, _index, _attestationRegistry, maxGas_)
        EIP712("FlatLevelQuoterHook", "1")
        Ownable(owner_)
    {}

    // ──── Hook Permissions ────

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // register in index
            beforeAddLiquidity: true, // block external LP (zero-liquidity pool)
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // flat pricing + delta override
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true, // hook returns exact amounts
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──── IQuoterHook ────

    function isLive() external pure override returns (bool) {
        return true;
    }

    /// @notice Indicative quote with hookData-aware pricing.
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

        return _priceWithState(zeroForOne, amountSpecified, isAttested, attester, state);
    }

    // ──── Hook Lifecycle ────

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        _registerInIndex(key, QuoterType.HOOKDATA, "");
        return IHooks.afterInitialize.selector;
    }

    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert LiquidityNotAllowed();
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Apply hookData curve update if present
        if (hookData.length > 0) {
            QuoterHookData memory hd = abi.decode(hookData, (QuoterHookData));
            if (hd.curveUpdateData.length > 0) {
                _applyCurveUpdate(key.toId(), hd.curveUpdateData);
            }
        }

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
            inputAmount = (absAmount * 1e18 + coefficient - 1) / coefficient; // round up
        }

        // Determine currencies
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Check inventory: ERC-20 balance + ERC-6909 claims
        uint256 erc20Bal = IERC20Minimal(Currency.unwrap(outputCurrency)).balanceOf(address(this));
        uint256 claimBal = poolManager.balanceOf(address(this), outputCurrency.toId());
        if (erc20Bal + claimBal < outputAmount) revert InsufficientInventory();

        // Settle output to PM: prefer burning ERC-6909 claims, then ERC-20
        if (claimBal >= outputAmount) {
            poolManager.burn(address(this), outputCurrency.toId(), outputAmount);
        } else if (claimBal > 0) {
            poolManager.burn(address(this), outputCurrency.toId(), claimBal);
            _settle(outputCurrency, address(this), outputAmount - claimBal);
        } else {
            _settle(outputCurrency, address(this), outputAmount);
        }

        // Accept input as ERC-6909 claims (PM doesn't hold user's ERC-20 yet during beforeSwap)
        poolManager.mint(address(this), inputCurrency.toId(), inputAmount);

        // Build BeforeSwapDelta
        // For exact input: hook absorbs +inputAmount from specified, provides -outputAmount to unspecified
        // For exact output: hook absorbs -outputAmount from specified, provides +inputAmount to unspecified
        BeforeSwapDelta bsd;
        if (isExactInput) {
            bsd = toBeforeSwapDelta(int128(uint128(inputAmount)), -int128(uint128(outputAmount)));
        } else {
            bsd = toBeforeSwapDelta(-int128(uint128(outputAmount)), int128(uint128(inputAmount)));
        }

        return (IHooks.beforeSwap.selector, bsd, 0);
    }

    // ──── Pricing ────

    function _price(PoolKey calldata, bool zeroForOne, int256 amountSpecified, bool isAttested, address attester)
        internal
        view
        override
        returns (uint256 outputAmount)
    {
        // This is called by the default getIndicativeQuote in BasePropAMMHook
        // (which won't be reached since we override getIndicativeQuote above)
        // but we implement it for completeness
        return
            _priceWithState(
                zeroForOne, amountSpecified, isAttested, attester, flatPricingState[PoolId.wrap(bytes32(0))]
            );
    }

    function _priceWithState(
        bool zeroForOne,
        int256 amountSpecified,
        bool isAttested,
        address,
        FlatPricingState memory state
    ) internal pure returns (uint256 outputAmount) {
        if (!state.live) return 0;

        uint256 amount = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint128 coefficient = zeroForOne ? state.bidCoefficient : state.askCoefficient;
        outputAmount = (amount * coefficient) / 1e18;

        if (isAttested && state.attestedDiscountBps > 0) {
            outputAmount = (outputAmount * (10_000 + state.attestedDiscountBps)) / 10_000;
        }
    }

    // ──── Curve Update Logic ────

    function _applyCurveUpdate(PoolId poolId, bytes memory curveUpdateData) internal {
        (FlatPricingState memory newState, PoolId updatePoolId, uint256 deadline, bytes memory sig) =
            abi.decode(curveUpdateData, (FlatPricingState, PoolId, uint256, bytes));

        if (PoolId.unwrap(updatePoolId) != PoolId.unwrap(poolId)) revert PoolMismatch();
        if (block.timestamp > deadline) revert ExpiredUpdate();

        bytes32 updateHash = keccak256(curveUpdateData);
        bytes32 existing = blockUpdateHash[poolId][block.number];

        if (existing == bytes32(0)) {
            _verifySignature(newState, poolId, deadline, sig);
            blockUpdateHash[poolId][block.number] = updateHash;
            flatPricingState[poolId] = newState;
            emit FlatPricingStateUpdated(poolId, newState);
        } else if (existing != updateHash) {
            revert ConflictingCurveUpdate();
        }
    }

    function _verifySignature(FlatPricingState memory state, PoolId poolId, uint256 deadline, bytes memory sig)
        internal
        view
    {
        bytes32 structHash = keccak256(
            abi.encode(
                FLAT_PRICING_UPDATE_TYPEHASH,
                state.bidCoefficient,
                state.askCoefficient,
                state.attestedDiscountBps,
                state.live,
                PoolId.unwrap(poolId),
                deadline
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, sig);
        if (signer != priceSigner) revert InvalidPriceSigner();
    }

    // ──── Inventory Management ────

    /// @notice Deposit ERC-20 tokens into the hook's inventory.
    function deposit(Currency token, uint256 amount) external onlyOwner {
        IERC20Minimal(Currency.unwrap(token)).transferFrom(msg.sender, address(this), amount);
        emit Deposit(token, amount);
    }

    /// @notice Withdraw tokens from the hook's inventory.
    ///         If the hook's ERC-20 balance is insufficient, automatically redeems
    ///         ERC-6909 claims via the PoolManager to cover the shortfall.
    function withdraw(Currency token, uint256 amount) external onlyOwner {
        uint256 erc20Bal = IERC20Minimal(Currency.unwrap(token)).balanceOf(address(this));
        if (erc20Bal < amount) {
            // Redeem claims to cover the shortfall
            poolManager.unlock(abi.encode(token, amount - erc20Bal));
        }
        IERC20Minimal(Currency.unwrap(token)).transfer(msg.sender, amount);
        emit Withdrawal(token, amount);
    }

    /// @notice Redeem ERC-6909 claims for ERC-20 tokens without withdrawing.
    ///         Claims accumulate as the hook receives swap input via `poolManager.mint()`.
    ///         This converts them back to ERC-20 in the hook's inventory.
    /// @param currency The currency to redeem claims for.
    /// @param amount The amount to redeem. Use `claimBalance()` to check available claims.
    function redeemClaims(Currency currency, uint256 amount) external onlyOwner {
        poolManager.unlock(abi.encode(currency, amount));
    }

    /// @dev Called by PM during `unlock`. Burns claims and takes ERC-20.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        return "";
    }

    /// @notice View the hook's ERC-6909 claim balance for a given currency.
    function claimBalance(Currency currency) external view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    // ──── Owner Functions ────

    /// @notice Update the flat pricing state for a pool.
    function updateFlatPricingState(PoolKey calldata key, FlatPricingState calldata state) external onlyOwner {
        flatPricingState[key.toId()] = state;
        emit FlatPricingStateUpdated(key.toId(), state);
    }

    /// @notice Toggle liveness for a pool and update the index.
    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner {
        flatPricingState[key.toId()].live = live;
        _setLive(key, live);
        emit PoolLivenessUpdated(key.toId(), live);
    }

    /// @notice Set the authorized price signer for hookData curve updates.
    function setPriceSigner(address _priceSigner) external onlyOwner {
        priceSigner = _priceSigner;
        emit PriceSignerUpdated(_priceSigner);
    }
}
