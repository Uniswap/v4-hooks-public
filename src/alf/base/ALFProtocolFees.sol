// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ALFProtocolFees
/// @author Uniswap Labs
/// @notice Protocol fee compliance for ALF hooks that bypass v4's native fee mechanism.
/// @dev    Mirrors aggregator-hooks/ProtocolFees.sol but avoids importing IV4FeeAdapter
///         (pinned to ^0.8.29 in the protocol-fees submodule), which is incompatible with
///         v4-core's =0.8.26 PoolManager. Uses raw staticcall for TOKEN_JAR() instead.
///         If the protocol-fees lib relaxes its pragma, this can be replaced with direct
///         inheritance from ProtocolFees.
/// @custom:security-contact security@uniswap.org
abstract contract ALFProtocolFees {
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Cached token-jar address resolved from the v4 protocol fee controller. Refreshed
    ///         lazily on the first fee collection or explicitly via {pollTokenJar}.
    address public tokenJar;

    /// @dev PoolManager whose protocol fee controller owns the token jar.
    IPoolManager private immutable _protocolFeePoolManager;

    /// @notice Emitted each time protocol fee is taken to the token jar.
    /// @param recipient The token-jar address that received the fee.
    /// @param currency  The currency the fee was paid in.
    /// @param amount    The fee amount taken to the jar.
    event ProtocolFeesCollected(address indexed recipient, Currency indexed currency, uint256 amount);

    /// @notice Emitted when {pollTokenJar} updates the cached jar address.
    /// @param newTokenJar The newly resolved jar address.
    event TokenJarUpdated(address indexed newTokenJar);

    constructor(IPoolManager poolManager_) {
        _protocolFeePoolManager = poolManager_;
    }

    /// @notice Resolve and cache the token jar from the v4 fee adapter.
    /// @dev    Permissionless — anyone can refresh after the fee controller updates its jar.
    /// @return The (newly cached) token jar address.
    function pollTokenJar() public returns (address) {
        address newTokenJar = _getTokenJar();
        if (tokenJar != newTokenJar) {
            tokenJar = newTokenJar;
            emit TokenJarUpdated(newTokenJar);
        }
        return tokenJar;
    }

    /// @dev Take the v4 protocol fee on the unspecified-side delta to the cached token jar.
    ///      No-op if the protocol fee for the swap direction is zero or no jar is configured.
    ///      Lazily polls the jar on first use.
    /// @param key             The swap's pool key.
    /// @param params          The swap params (used for direction and exact-input/output sense).
    /// @param unspecifiedDelta The unspecified-side delta of the swap (signed).
    /// @return feeAmount The amount taken to the jar (as a positive int128).
    function _applyProtocolFee(PoolKey calldata key, SwapParams calldata params, int128 unspecifiedDelta)
        internal
        returns (int128)
    {
        IPoolManager poolManager = _protocolFeePoolManager;
        uint24 protocolFee = _getProtocolFee(poolManager, params.zeroForOne, key.toId());
        if (protocolFee == 0) return 0;
        if (tokenJar == address(0)) pollTokenJar();
        if (tokenJar == address(0)) return 0;

        bool isExactInput = params.amountSpecified < 0;
        Currency unspecifiedCurrency = params.zeroForOne == isExactInput ? key.currency1 : key.currency0;
        uint256 absUnspecified = uint256(uint128(unspecifiedDelta < 0 ? -unspecifiedDelta : unspecifiedDelta));
        uint256 feeAmount = _calculateProtocolFeeAmount(protocolFee, isExactInput, absUnspecified);

        emit ProtocolFeesCollected(tokenJar, unspecifiedCurrency, feeAmount);
        poolManager.take(unspecifiedCurrency, tokenJar, feeAmount);
        return feeAmount.toInt256().toInt128();
    }

    function _calculateProtocolFeeAmount(uint24 protocolFee, bool isExactInput, uint256 amountUnspecified)
        internal
        pure
        returns (uint256)
    {
        if (isExactInput) {
            return FullMath.mulDivRoundingUp(amountUnspecified, protocolFee, ProtocolFeeLibrary.PIPS_DENOMINATOR);
        } else {
            return FullMath.mulDivRoundingUp(
                amountUnspecified, protocolFee, ProtocolFeeLibrary.PIPS_DENOMINATOR - protocolFee
            );
        }
    }

    function _getProtocolFee(IPoolManager poolManager, bool zeroForOne, PoolId poolId)
        internal
        view
        returns (uint24 protocolFee)
    {
        (,, uint24 raw,) = poolManager.getSlot0(poolId);
        protocolFee = zeroForOne ? raw.getZeroForOneFee() : raw.getOneForZeroFee();
    }

    function _getTokenJar() internal view returns (address currentJar) {
        IPoolManager poolManager = _protocolFeePoolManager;
        address feeController = poolManager.protocolFeeController();
        if (feeController == address(0) || feeController.code.length == 0) return address(0);
        (bool success, bytes memory data) = feeController.staticcall(abi.encodeWithSignature("TOKEN_JAR()"));
        if (success && data.length >= 32) currentJar = abi.decode(data, (address));
    }
}
