// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice Standard hookData encoding for PropAMM quoter hooks.
/// @dev Callers MUST encode hookData as `abi.encode(QuoterHookData(...))`.
///      Both fields are optional — pass empty bytes when not applicable.
struct QuoterHookData {
    bytes attestationData; // ABI-encoded attestation payload, or empty
    bytes curveUpdateData; // ABI-encoded signed curve update, or empty
}

/// @title IQuoterHook
/// @notice Standard interface implemented by PropAMM hooks on top of the v4 hook interface.
/// @dev Provides a uniform way for the router and auction hook to query indicative quotes.
interface IQuoterHook {
    /// @notice Get an indicative quote for routing purposes.
    /// @dev MUST be a view function. Callers invoke via staticcall.
    /// @dev MUST NOT revert under normal conditions. If the quoter cannot
    ///      price the requested swap, it SHOULD return 0.
    /// @dev The returned value is non-binding. The actual execution price
    ///      is determined by the hook's beforeSwap implementation.
    /// @param key The pool key for this quoter's pool.
    /// @param zeroForOne The swap direction.
    /// @param amountSpecified The swap amount. Negative = exact input.
    /// @param hookData ABI-encoded QuoterHookData struct, or empty bytes.
    /// @return outputAmount The indicative number of output tokens.
    ///         For exact input swaps, this is the expected output.
    ///         For exact output swaps, this is the required input.
    function getIndicativeQuote(PoolKey calldata key, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        external
        view
        returns (uint256 outputAmount);

    /// @notice Whether this quoter is currently live and accepting swaps.
    /// @dev Quoters SHOULD return true if the current curve is not stale.
    /// @dev Consumers SHOULD validate against observed behavior.
    function isLive() external view returns (bool);

    /// @notice The declared maximum gas for getIndicativeQuote execution.
    /// @dev Callers use this to set gas limits on staticcall invocations.
    /// @dev Quoters that exceed their declared maxGas will have their
    ///      getIndicativeQuote calls fail, resulting in router deprioritization.
    function maxGas() external view returns (uint32);
}
