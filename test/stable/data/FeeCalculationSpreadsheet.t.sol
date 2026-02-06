// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeCalculation} from "../../../src/stable/libraries/FeeCalculation.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";

/// @title FeeCalculationSpreadsheetTest
/// @notice Validates FeeCalculation library against spreadsheet-derived test vectors
/// @dev Test data is loaded from test/stable/data/fee_calculation_test_data.csv
/// CSV format: priceE5,closeFeeE12,farFeeE12,targetFeeE12 (all pre-scaled integers)
contract FeeCalculationSpreadsheetTest is Test {
    uint24 constant OPTIMAL_FEE_E6 = 90;
    uint160 constant REF = uint160(FixedPoint96.Q96); // reference sqrt price (1:1)
    uint256 constant TOLERANCE_E12 = 10_000; //10_000 / 1e12 = 0.00000001 = 0.000001%

    string constant DATA_PATH = "test/stable/data/fee_calculation_test_data.csv";

    function test_spreadsheetData_closeFee_farFee_targetFee() public view {
        string memory csv = vm.readFile(DATA_PATH);
        string[] memory lines = vm.split(csv, "\n");

        uint256 rowCount;
        for (uint256 i = 1; i < lines.length; i++) {
            if (bytes(lines[i]).length == 0) continue;

            string[] memory cols = vm.split(lines[i], ",");

            uint256 priceE5 = vm.parseUint(cols[0]);
            uint256 expectedCloseFeeE12 = vm.parseUint(cols[1]);
            uint256 expectedFarFeeE12 = vm.parseUint(cols[2]);
            uint256 expectedTargetFeeE12 = vm.parseUint(cols[3]);

            // Convert price to sqrtPriceX96 using Q192 space (same approach as committed tests)
            uint256 ammPriceX192 = uint256(REF) * uint256(REF) * priceE5 / 100_000;
            uint160 sqrtAmmPriceX96 = uint160(FixedPointMathLib.sqrt(ammPriceX192));
            uint256 priceRatioX96 = FeeCalculation.calculatePriceRatioX96(sqrtAmmPriceX96, REF);

            int256 closeFeeE12 = FeeCalculation.calculateCloseBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
            uint256 farFeeE12 = FeeCalculation.calculateFarBoundaryFee(priceRatioX96, OPTIMAL_FEE_E6);
            uint256 targetFeeE12 = farFeeE12 - uint256(closeFeeE12) / 2;

            assertApproxEqAbs(uint256(closeFeeE12), expectedCloseFeeE12, TOLERANCE_E12, "closeFee mismatch");
            assertApproxEqAbs(farFeeE12, expectedFarFeeE12, TOLERANCE_E12, "farFee mismatch");
            assertApproxEqAbs(targetFeeE12, expectedTargetFeeE12, TOLERANCE_E12, "targetFee mismatch");

            rowCount++;
        }

        assertGt(rowCount, 0, "No rows parsed from CSV");
    }
}
