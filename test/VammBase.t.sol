pragma solidity >=0.8.13;

import "forge-std/Test.sol";
 import "forge-std/console2.sol";
 import "./DatedIrsVammTestUtil.sol";
 import "../src/storage/LPPosition.sol";
import "../src/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import "../src/storage/LPPosition.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/SD59x18.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

contract ExposedVammBase {

    function calculateQuoteTokenDelta(
        int256 unbalancedQuoteTokenDelta,
        int256 baseTokenDelta,
        UD60x18 yearsUntilMaturity,
        UD60x18 currentOracleValue,
        UD60x18 spread
    ) public view returns (int256 balancedQuoteTokenDelta) {
        balancedQuoteTokenDelta = VAMMBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokenDelta,
            baseTokenDelta,
            yearsUntilMaturity,
            currentOracleValue,
            spread
        );
    }
}

// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

// TODO: Break up this growing test contract into more multiple separate tests for increased readability
contract VammBaseTest is DatedIrsVammTestUtil {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using SafeCastI256 for int256;

    ExposedVammBase vammBase;

    function setUp() public {
        vammBase = new ExposedVammBase();
    }

    function test_CalculateQuoteTokenDelta_0bpsSpread_VT() public {
        int256 baseTokenDelta = 1e6;
        int256 unbalancedQuoteTokenDelta = -baseTokenDelta * 15 / 10; // avg price 1.5%
        UD60x18 yearsUntilMaturity = convert(uint256(1)).div(convert(uint256(2))); // half of year
        UD60x18 currentOracleValue = convert(uint256(107)).div(convert(uint256(100))); // 1.07

        // quote token delta = -base * liquidity_index * (1 + fixed_rate * yearsUntilMaturity)
        // quote token delta = -1e6 *       1.07       * (1 + 0.015 * 0.5)
        // quote token delta = -1078025
        int256 quoteTokenDelta = vammBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokenDelta,
            baseTokenDelta,
            yearsUntilMaturity,
            currentOracleValue,
            ud60x18(0)
        );
        assertEq(quoteTokenDelta, -1078025);
    }

    function test_CalculateQuoteTokenDelta_0bpsSpread_FT() public {
        int256 baseTokenDelta = -1e6;
        int256 unbalancedQuoteTokenDelta = -baseTokenDelta * 15 / 10; // avg price 1.5%
        UD60x18 yearsUntilMaturity = convert(uint256(1)).div(convert(uint256(2))); // half of year
        UD60x18 currentOracleValue = convert(uint256(107)).div(convert(uint256(100))); // 1.07

        // quote token delta = -base * liquidity_index * (1 + fixed_rate * yearsUntilMaturity)
        // quote token delta = 1e6 *       1.07       * (1 + 0.015 * 0.5)
        // quote token delta = 1078025
        int256 quoteTokenDelta = vammBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokenDelta,
            baseTokenDelta,
            yearsUntilMaturity,
            currentOracleValue,
            ud60x18(0)
        );
        assertEq(quoteTokenDelta, 1078025);
    }

    function test_CalculateQuoteTokenDelta_50bpsSpread_VT() public {
        int256 baseTokenDelta = 1e6;
        int256 unbalancedQuoteTokenDelta = -baseTokenDelta * 15 / 10; // avg price 1.5%
        UD60x18 yearsUntilMaturity = convert(uint256(1)).div(convert(uint256(2))); // half of year
        UD60x18 currentOracleValue = convert(uint256(107)).div(convert(uint256(100))); // 1.07

        // quote token delta = -base * liquidity_index * (1 + fixed_rate * (1 - spread/2) * yearsUntilMaturity)
        // quote token delta = -1e6 *       1.07       * (1 + 0.015 * (1 - 0.005 / 2) * 0.5)          
        // quote token delta = -1078004
        int256 quoteTokenDelta = vammBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokenDelta,
            baseTokenDelta,
            yearsUntilMaturity,
            currentOracleValue,
            ud60x18(25e14)
        );
        assertEq(quoteTokenDelta, -1078004);
    }

    function test_CalculateQuoteTokenDelta_50bpsSpread_FT() public {
        int256 baseTokenDelta = -1e6;
        int256 unbalancedQuoteTokenDelta = -baseTokenDelta * 15 / 10; // avg price 1.5%
        UD60x18 yearsUntilMaturity = convert(uint256(1)).div(convert(uint256(2))); // half of year
        UD60x18 currentOracleValue = convert(uint256(107)).div(convert(uint256(100))); // 1.07

        // quote token delta = -base * liquidity_index * (1 + fixed_rate  * (1 + spread/2) * yearsUntilMaturity)
        // quote token delta = 1e6 *       1.07       * (1 + 0.015 * (1 + 0.005 / 2) * 0.5)                 
        // quote token delta = 1078045
        int256 quoteTokenDelta = vammBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokenDelta,
            baseTokenDelta,
            yearsUntilMaturity,
            currentOracleValue,
            ud60x18(25e14)
        );
        assertEq(quoteTokenDelta, 1078045);
    }
}