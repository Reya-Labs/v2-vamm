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
    function baseBetweenTicks(
        int24 _tickLower,
        int24 _tickUpper,
        int128 _liquidityPerTick
    ) public view returns (int256){
        return VAMMBase.baseBetweenTicks(_tickLower, _tickUpper, _liquidityPerTick);
    }

    function getPriceFromTick(
        int24 _tick
    ) public pure returns (UD60x18 price){
        price = VAMMBase.getPriceFromTick(_tick);
    }

    function calculateQuoteTokenDelta(
        int256 unbalancedQuoteTokenDelta,
        int256 baseTokenDelta,
        UD60x18 yearsUntilMaturity,
        UD60x18 currentOracleValue
    ) public pure returns (int256 balancedQuoteTokenDelta) {
        balancedQuoteTokenDelta = VAMMBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokenDelta,
            baseTokenDelta,
            yearsUntilMaturity,
            currentOracleValue
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

    function testFuzz_BaseBetweenTicks(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidity)
    public {
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        // Check that baseBetweenTicks and getLiquidityForBase are symetric
        liquidity = boundNewPositionLiquidityAmount(type(uint128).max, tickLower, tickUpper, liquidity);
        int256 baseAmount = vammBase.baseBetweenTicks(tickLower, tickUpper, liquidity);
        assertOffByNoMoreThan2OrAlmostEqual(getLiquidityForBase(tickLower, tickUpper, baseAmount), liquidity); // TODO: can we do better than off-by-two for small values? is it important?
    }

    function test_CalculateQuoteTokenDelta() public {
        int256 baseTokenDelta = 1e6;
        int256 unbalancedQuoteTokenDelta = -baseTokenDelta * 15 / 10; // avg price 1.5%
        UD60x18 yearsUntilMaturity = convert(uint256(1)).div(convert(uint256(2))); // half of year
        UD60x18 currentOracleValue = convert(uint256(107)).div(convert(uint256(100))); // 1.07

        // quote token delta = -base * liquidity_index * (1 + fixed_rate * yearsUntilMaturity)
        // quote token delta = -1e6 *       1.07       * (1 + 1.5 * 0.5) // todo: scaling is wrong
        // quote token delta = -1872500
        int256 quoteTokenDelta = vammBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokenDelta,
            baseTokenDelta,
            yearsUntilMaturity,
            currentOracleValue
        );
        assertEq(quoteTokenDelta, -1872500);
    }
}