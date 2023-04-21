pragma solidity >=0.8.13;

import "forge-std/Test.sol";
 import "forge-std/console2.sol";
 import "./DatedIrsVammTest.sol";
 import "../contracts/utils/SafeCastUni.sol";
 import "../contracts/VAMM/storage/LPPosition.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";
import "../contracts/utils/CustomErrors.sol";
import "../contracts/VAMM/storage/LPPosition.sol";
import { mulUDxInt } from "../contracts/utils/PrbMathHelper.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/src/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/src/SD59x18.sol";

// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

// TODO: Break up this growing test contract into more multiple separate tests for increased readability
contract VammTest_WithLiquidity is DatedIrsVammTest {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastUni for uint256;
    using SafeCastUni for uint128;

    uint128 ACCOUNT_1 = 1;
    uint160 ACCOUNT_1_LOWER_SQRTPRICEX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price = 0.01 = 1%
    uint160 ACCOUNT_1_UPPER_SQRTPRICEX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price = 0.0484 = 4.84%
    uint128 ACCOUNT_2 = 2;
    uint160 ACCOUNT_2_LOWER_SQRTPRICEX96 = uint160(15 * FixedPoint96.Q96 / 100); // 0.15 => price = 0.0225 = 2.25%
    uint160 ACCOUNT_2_UPPER_SQRTPRICEX96 = uint160(25 * FixedPoint96.Q96 / 100); // 0.25 => price = 0.0625 = 6.25%
    int24 ACCOUNT_1_TICK_LOWER = TickMath.getTickAtSqrtRatio(ACCOUNT_1_LOWER_SQRTPRICEX96);
    int24 ACCOUNT_1_TICK_UPPER = TickMath.getTickAtSqrtRatio(ACCOUNT_1_UPPER_SQRTPRICEX96);
    int24 ACCOUNT_2_TICK_LOWER = TickMath.getTickAtSqrtRatio(ACCOUNT_2_LOWER_SQRTPRICEX96);
    int24 ACCOUNT_2_TICK_UPPER = TickMath.getTickAtSqrtRatio(ACCOUNT_2_UPPER_SQRTPRICEX96);
    uint256 _mockLiquidityIndex = 2;
    UD60x18 mockLiquidityIndex = convert(_mockLiquidityIndex);
    int256 totalLiquidity;
    int256 liquidityToLeft;
    int256 liquidityToRight;

    function setUp() public {
        DatedIrsVamm.create(initMarketId, initSqrtPriceX96, immutableConfig, mutableConfig);
        vammId = uint256(keccak256(abi.encodePacked(initMarketId, initMaturityTimestamp)));
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);


        int128 requestedBaseAmount = 50_000_000_000;

        {
            // LP 1
            int256 executedBaseAmount = vamm.executeDatedMakerOrder(ACCOUNT_1,ACCOUNT_1_LOWER_SQRTPRICEX96,ACCOUNT_1_UPPER_SQRTPRICEX96, requestedBaseAmount);
            assertAlmostEqual(executedBaseAmount, requestedBaseAmount);
            totalLiquidity += executedBaseAmount;
        }
        {
            // LP 2
            int256 executedBaseAmount = vamm.executeDatedMakerOrder(ACCOUNT_2,ACCOUNT_2_LOWER_SQRTPRICEX96,ACCOUNT_2_UPPER_SQRTPRICEX96, requestedBaseAmount);
            assertAlmostEqual(executedBaseAmount, requestedBaseAmount);
            totalLiquidity += executedBaseAmount;
        }

        // We know that the current price is within the range of both LPs, so to calculate liquidity to the left we add:
        //    accumulator * distance_from_current_price_to_LP2_lower_tick
        // AND
        //    LP1_per-tick_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        liquidityToLeft = vamm.vars.accumulator.toInt256() * int256(vamm.vars.tick - ACCOUNT_2_TICK_LOWER);
        liquidityToLeft += vamm.vars._ticks[ACCOUNT_1_TICK_LOWER].liquidityNet * int256(ACCOUNT_2_TICK_LOWER - ACCOUNT_1_TICK_LOWER);
        // console2.log("liquidityToLeft ", liquidityToLeft);

        // We know that the current price is within the range of both LPs, so to calculate liquidity to the left we add:
        //    accumulator * distance_from_current_price_to_LP1_upper_tick
        // AND
        //    LP1_per-tick_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        liquidityToRight = vamm.vars.accumulator.toInt256() * int256(ACCOUNT_1_TICK_UPPER - vamm.vars.tick);
        liquidityToRight += -vamm.vars._ticks[ACCOUNT_2_TICK_UPPER].liquidityNet * int256(ACCOUNT_2_TICK_UPPER - ACCOUNT_1_TICK_UPPER);
        // console2.log("liquidityToRight", liquidityToRight);

        // console2.log("totalLiquidity ", totalLiquidity);
        assertEq(totalLiquidity, liquidityToLeft + liquidityToRight);
    }

    function test_GetAccountUnfilledBases() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);

        // Positions just opened so no filled balances
        {
            // LP 1
            (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(ACCOUNT_1);
            assertEq(baseBalancePool, 0);
            assertEq(quoteBalancePool, 0);
        }
        {
            // LP 2
            (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(ACCOUNT_2);
            assertEq(baseBalancePool, 0);
            assertEq(quoteBalancePool, 0);
        }
    }

    function test_Swap_MovingRight() public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);

        IVAMMBase.SwapParams memory params = IVAMMBase.SwapParams({
            recipient: address(this),
            baseAmountSpecified: 200_000_000_000, // TODO: there is not enough liquidity - should this really succeed?
            sqrtPriceLimitX96: ACCOUNT_2_UPPER_SQRTPRICEX96
        });

        // Mock the liquidity index for a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        // TODO: verify that return values are as expected
        // TODO: verify that updated VAMM state is as expected
        // TODO: what is the expected behaviour for orders that cannot be filled? If not "fail", how does the caller know how much was filled?
        console2.log("trackerFixedTokenDelta", trackerFixedTokenDelta);
        console2.log("trackerBaseTokenDelta", trackerBaseTokenDelta);
    }

    // function test_Swap_MovingLeft() public { // TODO!
    //     DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);

    //     IVAMMBase.SwapParams memory params = IVAMMBase.SwapParams({
    //         recipient: address(this),
    //         baseAmountSpecified: -1_000_000_000,
    //         sqrtPriceLimitX96: ACCOUNT_1_LOWER_SQRTPRICEX96
    //     });

    //     // Mock the liquidity index for a swap
    //     vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

    //     (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);
    //     console2.log("trackerFixedTokenDelta", trackerFixedTokenDelta);
    //     console2.log("trackerBaseTokenDelta", trackerBaseTokenDelta);
    // }
}