// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
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
import {BasePropAMMHook} from "./BasePropAMMHook.sol";
import {IPropAMMIndex, QuoterType} from "../interfaces/IPropAMMIndex.sol";
import {IAttestationRegistry, Attestation} from "../interfaces/IAttestationRegistry.sol";
import {QuoterHookData} from "../interfaces/IQuoterHook.sol";

/// @title FlatQuoterBase
/// @notice Shared base for flat-price quoter hooks. Provides flat coefficient pricing,
///         EIP-712 signed curve updates, inventory management (deposit/withdraw/claims),
///         and PropAMMIndex registration. Subclasses implement `_beforeSwap()` and
///         `getHookPermissions()`, and may override `withdraw()` and `getIndicativeQuote()`.
abstract contract FlatQuoterBase is BasePropAMMHook, EIP712, Ownable2Step, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    struct FlatPricingState {
        uint128 bidCoefficient; // Price coefficient for zeroForOne, 1e18-scaled
        uint128 askCoefficient; // Price coefficient for oneForZero, 1e18-scaled
        uint16 attestedDiscountBps; // Discount for attested flow (bps)
        bool live;
    }

    bytes32 private constant FLAT_PRICING_UPDATE_TYPEHASH = keccak256(
        "FlatPricingUpdate(uint128 bidCoefficient,uint128 askCoefficient,uint16 attestedDiscountBps,bool live,bytes32 poolId,uint256 deadline)"
    );

    // ──── State ────

    mapping(PoolId => FlatPricingState) public flatPricingState;
    mapping(PoolId => mapping(uint256 => bytes32)) internal blockUpdateHash;
    address public priceSigner;

    // ──── Events ────

    event FlatPricingStateUpdated(PoolId indexed poolId, FlatPricingState state);
    event PoolLivenessUpdated(PoolId indexed poolId, bool isLive);
    event PriceSignerUpdated(address indexed newSigner);
    event Deposit(Currency indexed token, uint256 amount);
    event Withdrawal(Currency indexed token, uint256 amount);

    // ──── Errors ────

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
        address owner_,
        string memory eip712Name,
        string memory eip712Version
    )
        BasePropAMMHook(_poolManager, _index, _attestationRegistry, maxGas_)
        EIP712(eip712Name, eip712Version)
        Ownable(owner_)
    {}

    // ──── IQuoterHook ────

    function isLive() external pure virtual override returns (bool) {
        return true;
    }

    /// @notice Indicative quote with hookData-aware pricing.
    /// @dev Virtual — subclasses may override to add inventory caps or other constraints.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        virtual
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

    // ──── Internal: Pricing ────

    function _price(PoolKey calldata, bool zeroForOne, int256 amountSpecified, bool isAttested, address attester)
        internal
        view
        override
        returns (uint256)
    {
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

    // ──── Internal: Curve Updates ────

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

    // ──── Internal: Settlement Helpers ────

    /// @dev Settle output to PM. Prefers burning ERC-6909 claims, then ERC-20.
    function _settleOutput(Currency currency, uint256 amount) internal {
        uint256 claimBal = poolManager.balanceOf(address(this), currency.toId());
        if (claimBal >= amount) {
            poolManager.burn(address(this), currency.toId(), amount);
        } else if (claimBal > 0) {
            poolManager.burn(address(this), currency.toId(), claimBal);
            _settle(currency, address(this), amount - claimBal);
        } else {
            _settle(currency, address(this), amount);
        }
    }

    /// @dev Construct BeforeSwapDelta from swap params and computed amounts.
    function _buildBeforeSwapDelta(SwapParams calldata params, uint256 inputAmount, uint256 outputAmount)
        internal
        pure
        returns (BeforeSwapDelta)
    {
        bool isExactInput = params.amountSpecified < 0;
        if (isExactInput) {
            return toBeforeSwapDelta(int128(uint128(inputAmount)), -int128(uint128(outputAmount)));
        } else {
            return toBeforeSwapDelta(-int128(uint128(outputAmount)), int128(uint128(inputAmount)));
        }
    }

    // ──── Inventory Management ────

    /// @notice Deposit ERC-20 tokens into the hook's inventory.
    function deposit(Currency token, uint256 amount) external onlyOwner {
        IERC20Minimal(Currency.unwrap(token)).transferFrom(msg.sender, address(this), amount);
        emit Deposit(token, amount);
    }

    /// @notice Withdraw tokens. Subclasses may override to add Aave or other redemption sources.
    function withdraw(Currency token, uint256 amount) external virtual onlyOwner {
        uint256 erc20Bal = IERC20Minimal(Currency.unwrap(token)).balanceOf(address(this));
        if (erc20Bal < amount) {
            poolManager.unlock(abi.encode(token, amount - erc20Bal));
        }
        IERC20Minimal(Currency.unwrap(token)).transfer(msg.sender, amount);
        emit Withdrawal(token, amount);
    }

    /// @notice Convert ERC-6909 claims to ERC-20 tokens.
    function redeemClaims(Currency currency, uint256 amount) external onlyOwner {
        poolManager.unlock(abi.encode(currency, amount));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(poolManager));
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, address(this), amount);
        return "";
    }

    /// @notice View the hook's ERC-6909 claim balance for a given currency.
    function claimBalance(Currency currency) external view returns (uint256) {
        return poolManager.balanceOf(address(this), currency.toId());
    }

    // ──── Owner Configuration ────

    function updateFlatPricingState(PoolKey calldata key, FlatPricingState calldata state) external onlyOwner {
        flatPricingState[key.toId()] = state;
        emit FlatPricingStateUpdated(key.toId(), state);
    }

    function setPoolLive(PoolKey calldata key, bool live) external onlyOwner {
        flatPricingState[key.toId()].live = live;
        _setLive(key, live);
        emit PoolLivenessUpdated(key.toId(), live);
    }

    function setPriceSigner(address _priceSigner) external onlyOwner {
        priceSigner = _priceSigner;
        emit PriceSignerUpdated(_priceSigner);
    }
}
