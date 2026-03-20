// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {BaseHook} from "../../base/BaseHook.sol";
import {DeltaResolver} from "@uniswap/v4-periphery/src/base/DeltaResolver.sol";
import {IALFHook, ALFHookData} from "../interfaces/IALFHook.sol";
import {IAttestationRegistry, Attestation} from "../interfaces/IAttestationRegistry.sol";

/// @title BaseALFHook
/// @notice Abstract base contract for ALF hooks. Provides attestation resolution
///         and the IALFHook implementation. Quoters extend this and implement
///         _price() with their proprietary pricing logic.
/// @dev Follows the same BaseHook + DeltaResolver dual-inheritance pattern as BaseTokenWrapperHook.
abstract contract BaseALFHook is BaseHook, DeltaResolver, IALFHook {
    IAttestationRegistry public immutable attestationRegistry;
    uint32 private immutable _maxGas;

    constructor(
        IPoolManager _poolManager,
        IAttestationRegistry _attestationRegistry,
        uint32 maxGas_
    ) BaseHook(_poolManager) {
        attestationRegistry = _attestationRegistry;
        _maxGas = maxGas_;
    }

    // ──── IALFHook ────

    /// @inheritdoc IALFHook
    function maxGas() external view override returns (uint32) {
        return _maxGas;
    }

    /// @inheritdoc IALFHook
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        virtual
        override
        returns (uint256 outputAmount)
    {
        bytes memory attestationData;
        if (hookData.length > 0) {
            ALFHookData memory hd = abi.decode(hookData, (ALFHookData));
            attestationData = hd.attestationData;
        }
        (bool isAttested, address attester) = _resolveAttestation(attestationData);
        return _price(key, zeroForOne, amountSpecified, isAttested, attester);
    }

    /// @inheritdoc IALFHook
    function isLive() external view virtual override returns (bool);

    // ──── Reserves (default: no off-pool reserves) ────

    /// @inheritdoc IALFHook
    /// @dev Default returns (0, 0). Hooks that manage off-pool capital (JIT, rehypothecation)
    ///      should override to report their true TVL.
    function getReserves(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    /// @inheritdoc IALFHook
    /// @dev Default returns (0, 0). Override for hooks with off-pool reserves.
    function getEffectiveLiquidity(PoolKey calldata) external view virtual override returns (uint256, uint256) {
        return (0, 0);
    }

    // ──── Price-bounded simulation (default: unsupported) ────

    /// @inheritdoc IALFHook
    /// @dev Default returns (0, 0). Spread quoters override with SwapSimulator-backed
    ///      implementation. Hooks that cannot support price-bounded simulation (e.g.,
    ///      flat quoters, external wrappers) keep this default.
    function swapToPrice(PoolKey calldata, bool, int256, uint160, bytes calldata)
        external
        view
        virtual
        override
        returns (uint256, uint256)
    {
        return (0, 0);
    }

    // ──── Internal: Attestation ────

    /// @dev Parse and verify attestation from raw bytes.
    /// @return isAttested Whether a valid attestation was provided.
    /// @return attester The attester address (zero if not attested).
    function _resolveAttestation(bytes memory attestationData)
        internal
        view
        returns (bool isAttested, address attester)
    {
        if (attestationData.length == 0) return (false, address(0));
        (Attestation memory att, bool valid) = attestationRegistry.verify(attestationData);
        return (valid, valid ? att.attester : address(0));
    }

    // ──── Abstract: Pricing ────

    /// @dev Subclasses MUST implement pricing logic.
    /// @param key The pool key.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified The swap amount. Negative = exact input.
    /// @param isAttested Whether the swap has a valid attestation.
    /// @param attester The attester address (zero if not attested).
    /// @return outputAmount The quoted output.
    function _price(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bool isAttested, address attester)
        internal
        view
        virtual
        returns (uint256 outputAmount);

    // ──── DeltaResolver: _pay ────

    /// @dev Transfer tokens to the pool manager for delta settlement.
    function _pay(Currency token, address, uint256 amount) internal override {
        token.transfer(address(poolManager), amount);
    }
}
