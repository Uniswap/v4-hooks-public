import { parseAbi } from "viem";

/**
 * The StablePairHook surface the keeper uses, transcribed from the Solidity source (PoolId is bytes32):
 * - src/stable/interfaces/IStableFeeConfiguration.sol: struct StableFeeConfig (line 8), errors (lines 26-41)
 * - src/stable/base/StableFeeConfiguration.sol: batchUpdateFeeConfig (line 52), feeConfig (line 66)
 * - src/interfaces/IDynamicFeeHook.sol: PoolNotInitialized (line 12)
 * - OpenZeppelin IAccessControl: AccessControlUnauthorizedAccount, raised by onlyRole(CONFIG_MANAGER_ROLE)
 *
 * feeConfig returns four named values rather than the struct, so viem decodes it as a 4-element array.
 * The errors are here so a revert decodes to its name instead of a bare selector.
 */
export const stablePairHookAbi = parseAbi([
  "struct StableFeeConfig { uint24 k; uint24 optimalFeeE6; uint8 targetMultiplier; uint160 referenceSqrtPriceX96; }",
  "function batchUpdateFeeConfig(bytes32[] poolIds, StableFeeConfig[] feeConfigs)",
  "function feeConfig(bytes32 poolId) view returns (uint24 k, uint24 optimalFeeE6, uint8 targetMultiplier, uint160 referenceSqrtPriceX96)",
  "error LengthMismatch()",
  "error InvalidK(uint256 k)",
  "error InvalidOptimalFeeE6(uint256 optimalFeeE6)",
  "error InvalidReferenceSqrtPriceX96(uint256 invalidSqrtPrice)",
  "error InvalidTargetMultiplier(uint256 targetMultiplier)",
  "error PoolNotInitialized(bytes32 poolId)",
  "error AccessControlUnauthorizedAccount(address account, bytes32 neededRole)",
]);
