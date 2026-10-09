// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StableFeeConfig} from "../../src/stable/interfaces/IStableFeeConfiguration.sol";

/// @notice One entry of `pools` in tooling/out/pools.4663.json
struct PoolEntry {
    string symbol;
    address stock;
    address currency0;
    address currency1;
    bool stockIsCurrency0;
    uint24 fee;
    int24 tickSpacing;
    uint160 sqrtPriceX96;
    int24 tickLower;
    int24 tickUpper;
    uint16 targetBps;
    StableFeeConfig feeConfig;
}

/// @notice Reads the pool config JSON the tooling generator writes (tooling/out/pools.4663.json)
library PoolConfigLib {
    /// @notice Every entry of `$.pools`. Fields are read by JSON path, so key order in the file does not matter.
    function load(Vm vm, string memory path) internal view returns (PoolEntry[] memory pools) {
        string memory json = vm.readFile(path);
        // forge 1.7.1 can neither abi.decode `$.pools` as bytes[] nor parseJsonStringArray over it, so count the entries
        uint256 n;
        while (vm.keyExistsJson(json, string.concat("$.pools[", vm.toString(n), "]"))) {
            n++;
        }
        pools = new PoolEntry[](n);
        for (uint256 i = 0; i < n; i++) {
            pools[i] = _entry(vm, json, string.concat("$.pools[", vm.toString(i), "]"));
        }
    }

    /// @notice The chain id the file was generated for
    function chainId(Vm vm, string memory path) internal view returns (uint256) {
        return vm.parseJsonUint(vm.readFile(path), "$.chainId");
    }

    /// @notice Reverts unless the entry keys a StablePairHook pool for its stock: the dynamic-fee flag, sorted
    ///         currencies, and the stock on the side `stockIsCurrency0` names
    function validate(PoolEntry memory e) internal pure {
        require(
            e.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG,
            string.concat(e.symbol, ": fee must be the dynamic-fee flag 0x800000")
        );
        require(e.currency0 < e.currency1, string.concat(e.symbol, ": currency0 must sort below currency1"));
        require(
            (e.stockIsCurrency0 ? e.currency0 : e.currency1) == e.stock,
            string.concat(e.symbol, ": stock must be currency0 when stockIsCurrency0, else currency1")
        );
    }

    /// @dev The prices are decimal strings in the file; parseJsonUint reads them exactly. SafeCast reverts instead of
    ///      truncating a value that does not fit its field.
    function _entry(Vm vm, string memory json, string memory p) private pure returns (PoolEntry memory e) {
        e.symbol = vm.parseJsonString(json, string.concat(p, ".symbol"));
        e.stock = vm.parseJsonAddress(json, string.concat(p, ".stock"));
        e.currency0 = vm.parseJsonAddress(json, string.concat(p, ".currency0"));
        e.currency1 = vm.parseJsonAddress(json, string.concat(p, ".currency1"));
        e.stockIsCurrency0 = vm.parseJsonBool(json, string.concat(p, ".stockIsCurrency0"));
        e.fee = SafeCast.toUint24(vm.parseJsonUint(json, string.concat(p, ".fee")));
        e.tickSpacing = SafeCast.toInt24(vm.parseJsonInt(json, string.concat(p, ".tickSpacing")));
        e.sqrtPriceX96 = SafeCast.toUint160(vm.parseJsonUint(json, string.concat(p, ".sqrtPriceX96")));
        e.tickLower = SafeCast.toInt24(vm.parseJsonInt(json, string.concat(p, ".tickLower")));
        e.tickUpper = SafeCast.toInt24(vm.parseJsonInt(json, string.concat(p, ".tickUpper")));
        e.targetBps = SafeCast.toUint16(vm.parseJsonUint(json, string.concat(p, ".targetBps")));
        e.feeConfig.k = SafeCast.toUint24(vm.parseJsonUint(json, string.concat(p, ".feeConfig.k")));
        e.feeConfig.optimalFeeE6 =
            SafeCast.toUint24(vm.parseJsonUint(json, string.concat(p, ".feeConfig.optimalFeeE6")));
        e.feeConfig.targetMultiplier =
            SafeCast.toUint8(vm.parseJsonUint(json, string.concat(p, ".feeConfig.targetMultiplier")));
        e.feeConfig.referenceSqrtPriceX96 =
            SafeCast.toUint160(vm.parseJsonUint(json, string.concat(p, ".feeConfig.referenceSqrtPriceX96")));
    }
}
