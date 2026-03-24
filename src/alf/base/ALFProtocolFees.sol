// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ProtocolFeeLibrary} from "@uniswap/v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @title ALFProtocolFees
/// @notice Protocol fee compliance for ALF hooks that bypass v4's native fee mechanism.
/// @dev    Mirrors aggregator-hooks/ProtocolFees.sol but avoids importing IV4FeeAdapter
///         (pinned to ^0.8.29 in the protocol-fees submodule), which is incompatible with
///         v4-core's =0.8.26 PoolManager. Uses raw staticcall for TOKEN_JAR() instead.
///         If the protocol-fees lib relaxes its pragma, this can be replaced with direct
///         inheritance from ProtocolFees.
abstract contract ALFProtocolFees {
    using ProtocolFeeLibrary for uint24;
    using ProtocolFeeLibrary for uint16;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    address public tokenJar;

    event ProtocolFeesCollected(address indexed recipient, Currency indexed currency, uint256 amount);
    event TokenJarUpdated(address indexed newTokenJar);

    /// @notice Resolve and cache the token jar from the v4 fee adapter.
    function pollTokenJar() public virtual returns (address);

    function _applyProtocolFee(
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata params,
        int128 unspecifiedDelta
    ) internal returns (int128) {
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
        return int128(uint128(feeAmount));
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

    function _getTokenJar(IPoolManager poolManager) internal view returns (address currentJar) {
        address feeController = poolManager.protocolFeeController();
        if (feeController == address(0) || feeController.code.length == 0) return address(0);
        (bool success, bytes memory data) = feeController.staticcall(abi.encodeWithSignature("TOKEN_JAR()"));
        if (success && data.length >= 32) currentJar = abi.decode(data, (address));
    }
}
