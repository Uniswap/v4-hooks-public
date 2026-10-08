// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {StableFeeConfig} from "../../stable/interfaces/IStableFeeConfiguration.sol";

/// @notice The StableFeeConfiguration view the vault reads each pool's keeper reference price from; the hook exposes
///         it, but IStableFeeConfiguration does not declare it
interface IStableFeeConfigView {
    function feeConfig(PoolId poolId) external view returns (StableFeeConfig memory);
}
