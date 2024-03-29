pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./DatedIrsVammTestUtil.sol";
import "../src/storage/LPPosition.sol";
import "../src/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import "../src/storage/LPPosition.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, convert, unwrap, ud60x18, uMAX_UD60x18, uUNIT, UNIT } from "@prb/math/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/SD59x18.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

contract DatedIrsVammTest is DatedIrsVammTestUtil {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using LPPosition for LPPosition.Data;

    int128 constant BASE_AMOUNT_PER_LP = 50_000_000_000;
    uint128 constant ACCOUNT_1 = 1;
    // TL -46055
    // TU -30285
    uint160 constant ACCOUNT_1_LOWER_SQRTPRICEX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price = 0.01 = 1%
    uint160 constant ACCOUNT_1_UPPER_SQRTPRICEX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price = 0.0484 = 4.84%
    uint128 constant ACCOUNT_2 = 2;
    // TL -37945
    // TU -27728
    uint160 constant ACCOUNT_2_LOWER_SQRTPRICEX96 = uint160(15 * FixedPoint96.Q96 / 100); // 0.15 => price = 0.0225 = 2.25%
    uint160 constant ACCOUNT_2_UPPER_SQRTPRICEX96 = uint160(25 * FixedPoint96.Q96 / 100); // 0.25 => price = 0.062
    int24 ACCOUNT_1_TICK_LOWER = TickMath.getTickAtSqrtRatio(ACCOUNT_1_LOWER_SQRTPRICEX96);
    int24 ACCOUNT_1_TICK_UPPER = TickMath.getTickAtSqrtRatio(ACCOUNT_1_UPPER_SQRTPRICEX96);
    int24 ACCOUNT_2_TICK_LOWER = TickMath.getTickAtSqrtRatio(ACCOUNT_2_LOWER_SQRTPRICEX96);
    int24 ACCOUNT_2_TICK_UPPER = TickMath.getTickAtSqrtRatio(ACCOUNT_2_UPPER_SQRTPRICEX96);
    uint256 _mockLiquidityIndex = 2;
    UD60x18 mockLiquidityIndex = convert(_mockLiquidityIndex);
    int256 baseTradeableToLeft;
    int256 baseTradeableToRight;
    ExposedDatedIrsVamm vamm;
    
    uint32[] internal times;
    int24[] internal observedTicks;

    function setUp() public {

        vammId = uint256(keccak256(abi.encodePacked(initMarketId, uint32(initMaturityTimestamp))));
        vamm = new ExposedDatedIrsVamm(vammId);

        times = new uint32[](1);
        times[0] = uint32(block.timestamp);

        observedTicks = new int24[](1);
        observedTicks[0] = initialTick;

        vamm.create(initMarketId, initSqrtPriceX96, times, observedTicks, immutableConfig, mutableConfig);
        vamm.setMakerPositionsPerAccountLimit(3);
        vamm.increaseObservationCardinalityNext(16);

        // console2.log("requestedBaseAmount (per LP)  ", BASE_AMOUNT_PER_LP);

        {
            // LP 1
            int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
            vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, ACCOUNT_1_TICK_LOWER,ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);
        }
        {
            // LP 2
            int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, BASE_AMOUNT_PER_LP);
            vamm.executeDatedMakerOrder(ACCOUNT_2, initMarketId, ACCOUNT_2_TICK_LOWER,ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        }

        // We know that the current price is within the range of both LPs, so to calculate base tokens available to trade to the left we add:
        //    liquidity * distance_from_current_price_to_LP2_lower_tick
        // AND
        //    LP1_liquidity_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        baseTradeableToLeft += vamm.baseBetweenTicks(ACCOUNT_2_TICK_LOWER, vamm.tick(), vamm.liquidity().toInt());
        baseTradeableToLeft += vamm.baseBetweenTicks(ACCOUNT_1_TICK_LOWER, ACCOUNT_2_TICK_LOWER, vamm.ticks( ACCOUNT_1_TICK_LOWER).liquidityNet);
        // console2.log("baseTradeableToLeft  ", baseTradeableToLeft);

        // We know that the current price is within the range of both LPs, so to calculate base tokens available to trade to the right we add:
        //    liquidity * distance_from_current_price_to_LP1_upper_tick
        // AND
        //    LP2_per-tick_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        baseTradeableToRight += vamm.baseBetweenTicks(vamm.tick(), ACCOUNT_1_TICK_UPPER, vamm.liquidity().toInt());
        baseTradeableToRight += vamm.baseBetweenTicks(ACCOUNT_1_TICK_UPPER, ACCOUNT_2_TICK_UPPER, -vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityNet);
        // console2.log("baseTradeableToRight ", baseTradeableToRight);
    }

    function test_TradeableBaseTokens() public {
        assertAlmostEqual(BASE_AMOUNT_PER_LP * 2, baseTradeableToLeft + baseTradeableToRight);
    }

    function test_CorrectCreation() public {
        assertEq(vamm.tick(), TickMath.getTickAtSqrtRatio(initSqrtPriceX96));
    }

    function test_PositionsPerAccountLimit() public {
        // 2nd position
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, ACCOUNT_1_TICK_LOWER - 1,ACCOUNT_1_TICK_UPPER + 1, 1000);
        // 3rd position
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, ACCOUNT_1_TICK_LOWER + 1,ACCOUNT_1_TICK_UPPER + 1, 1000);
        // 4th position
        vm.expectRevert(abi.encodeWithSelector(DatedIrsVamm.TooManyLpPositions.selector, ACCOUNT_1));
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, ACCOUNT_1_TICK_LOWER + 2,ACCOUNT_1_TICK_UPPER + 1, 1000);

        // 4th position
        vm.expectRevert(abi.encodeWithSelector(DatedIrsVamm.TooManyLpPositions.selector, ACCOUNT_1));
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, ACCOUNT_1_TICK_LOWER - 2,ACCOUNT_1_TICK_UPPER - 1, 1000);
    }

    function test_GetAccountUnfilledBalances() public {
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
        int256 amountSpecified =  500_000_000;

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: ACCOUNT_2_UPPER_SQRTPRICEX96
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (, int256 baseTokenDelta) = vamm.vammSwap(params);
        // console2.log("SWAP 1 FT D", quoteTokenDelta);
        // console2.log("SWAP 1 BT D", baseTokenDelta);

        assertAlmostEqual(baseTokenDelta, -amountSpecified);
    }

    function test_Swap_MovingLeft() public {
        int256 amountSpecified =  -500_000_000;

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MIN_TICK + 1)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (, int256 baseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(baseTokenDelta, -amountSpecified);
    }

    function test_Swap_MovingMaxRight() public {
        int24 tickLimit = ACCOUNT_2_TICK_UPPER + 1;

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: 500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToRight
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 quoteTokenDelta, int256 baseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(baseTokenDelta, -baseTradeableToRight);
        assertEq(vamm.tick(), tickLimit);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit));
    }

    function test_Swap_MovingMaxLeft() public {
        int24 tickLimit = MIN_TICK + 1;

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (, int256 baseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(baseTokenDelta, baseTradeableToLeft);
        assertEq(vamm.tick(), tickLimit);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit));
    }

    function test_Swap_MovingMaxLeft_ExtendTickLimits() public {
        int24 tickLimit = MIN_TICK + 1;

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (, int256 baseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(baseTokenDelta, baseTradeableToLeft);
        assertEq(vamm.tick(), tickLimit);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit));

        VammConfiguration.Mutable memory mutableConfig = VammConfiguration.Mutable({
            priceImpactPhi: ud60x18(1e17), // 0.1
            priceImpactBeta: ud60x18(125e15), // 0.125
            spread: ud60x18(3e15), // spread / 2 = 0.3%
            rateOracle: IRateOracle(mockRateOracle),
            minTick: MIN_TICK - 1000,
            maxTick: MAX_TICK + 1000
        });

        vamm.configureVamm(mutableConfig);

        /// MINT 

        int128 requestedLiquidityAmount = getLiquidityForBase(MIN_TICK - 1000 + 1, MIN_TICK, BASE_AMOUNT_PER_LP);
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, MIN_TICK - 1000 + 1,MIN_TICK, requestedLiquidityAmount);

        /// EXECUTE ANOTHER SWAP

        int24 tickLimit2 = MIN_TICK - 1000 + 1;

        DatedIrsVamm.SwapParams memory params2 = DatedIrsVamm.SwapParams({
            amountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit2)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (, int256 baseTokenDelta2) = vamm.vammSwap(params2);

        assertGt(baseTokenDelta2, 0);
        assertEq(vamm.tick(), tickLimit2 - 1);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit2));
    }

    function test_Swap_MovingMaxRight_ExtendTickLimits() public {
        int24 tickLimit = MAX_TICK - 1;

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: 500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToRight
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (, int256 baseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(baseTokenDelta, -baseTradeableToRight);
        assertEq(vamm.tick(), tickLimit);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit));

        VammConfiguration.Mutable memory mutableConfig = VammConfiguration.Mutable({
            priceImpactPhi: ud60x18(1e17), // 0.1
            priceImpactBeta: ud60x18(125e15), // 0.125
            spread: ud60x18(3e15), // spread / 2 = 0.3%
            rateOracle: IRateOracle(mockRateOracle),
            minTick: MIN_TICK - 1000,
            maxTick: MAX_TICK + 1000
        });

        vamm.configureVamm(mutableConfig);

        /// MINT 

        int128 requestedLiquidityAmount = getLiquidityForBase(MAX_TICK, MAX_TICK + 1000 + 1, BASE_AMOUNT_PER_LP);
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, MAX_TICK, MAX_TICK + 1000 - 1, requestedLiquidityAmount);

        /// EXECUTE ANOTHER SWAP

        int24 tickLimit2 = MAX_TICK + 1000 - 1;

        DatedIrsVamm.SwapParams memory params2 = DatedIrsVamm.SwapParams({
            amountSpecified: 500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit2)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (, int256 baseTokenDelta2) = vamm.vammSwap(params2);

        assertLt(baseTokenDelta2, 0);
        assertEq(vamm.tick(), tickLimit2);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit2));
    }

    function test_RevertWhen_ReduceTickLimits_TickOutside() public {
        test_Swap_MovingMaxLeft();

        int24 NEW_MIN_TICK = MIN_TICK + 1000;
        int24 NEW_MAX_TICK = MAX_TICK - 1000;

        VammConfiguration.Mutable memory mutableConfig = VammConfiguration.Mutable({
            priceImpactPhi: ud60x18(1e17), // 0.1
            priceImpactBeta: ud60x18(125e15), // 0.125
            spread: ud60x18(3e15), // spread / 2 = 0.3%
            rateOracle: IRateOracle(mockRateOracle),
            minTick: NEW_MIN_TICK,
            maxTick: NEW_MAX_TICK
        });

        vm.expectRevert(abi.encodeWithSelector(DatedIrsVamm.ExceededTickLimits.selector, NEW_MIN_TICK, NEW_MAX_TICK));
        vamm.configureVamm(mutableConfig);

        // MOVE TICK BACK 
        DatedIrsVamm.SwapParams memory params0 = DatedIrsVamm.SwapParams({
            amountSpecified: 66668361499, 
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MAX_TICK - 1)
        });
        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        vamm.vammSwap(params0);
        vamm.configureVamm(mutableConfig);

        /// MINTS

        vm.expectRevert(bytes("TLMR"));
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, MIN_TICK, NEW_MIN_TICK + 1, 10000);
        vm.expectRevert(bytes("TUMR"));
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, NEW_MIN_TICK + 1, MAX_TICK, 10000);

        int128 requestedLiquidityAmount = getLiquidityForBase(-6450, 0, BASE_AMOUNT_PER_LP);
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, -6450, 0, requestedLiquidityAmount);

        /// SWAPS

        DatedIrsVamm.SwapParams memory params1 = DatedIrsVamm.SwapParams({
            amountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MIN_TICK + 1)
        });
        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        vm.expectRevert(bytes("SPL"));
        vamm.vammSwap(params1);

        DatedIrsVamm.SwapParams memory params2 = DatedIrsVamm.SwapParams({
            amountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(NEW_MIN_TICK + 1)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (, int256 baseTokenDelta2) = vamm.vammSwap(params2);

        assertGt(baseTokenDelta2, 0);
        assertEq(vamm.tick(), NEW_MIN_TICK + 1);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(NEW_MIN_TICK + 1));
    }

    function test_ReduceTickLimits() public {
        test_Swap_MovingLeft();

        int24 NEW_MIN_TICK = MIN_TICK + 1000;
        int24 NEW_MAX_TICK = MAX_TICK - 1000;

        VammConfiguration.Mutable memory mutableConfig = VammConfiguration.Mutable({
            priceImpactPhi: ud60x18(1e17), // 0.1
            priceImpactBeta: ud60x18(125e15), // 0.125
            spread: ud60x18(3e15), // spread / 2 = 0.3%
            rateOracle: IRateOracle(mockRateOracle),
            minTick: NEW_MIN_TICK,
            maxTick: NEW_MAX_TICK
        });

        vamm.configureVamm(mutableConfig);

        /// MINT 

        vm.expectRevert(bytes("TLMR"));
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, MIN_TICK, NEW_MIN_TICK + 1, 10000);

        int128 requestedLiquidityAmount = getLiquidityForBase(-6450, 0, BASE_AMOUNT_PER_LP);
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, -6450, 0, requestedLiquidityAmount);

        /// EXECUTE ANOTHER SWAP

        DatedIrsVamm.SwapParams memory params2 = DatedIrsVamm.SwapParams({
            amountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(NEW_MIN_TICK + 1)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (, int256 baseTokenDelta2) = vamm.vammSwap(params2);

        assertGt(baseTokenDelta2, 0);
        assertEq(vamm.tick(), NEW_MIN_TICK + 1);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(NEW_MIN_TICK + 1));
    }

    function test_Burn_After_ReduceTickLimits() public {

        int24 NEW_MIN_TICK = MIN_TICK + 1000;
        // int24 NEW_MAX_TICK = MAX_TICK - 1000;

        // MINT BETWEEN OLD MIN & MAX TICKS
        int128 requestedLiquidityAmount = getLiquidityForBase(MIN_TICK, MAX_TICK, 100e18);
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, MIN_TICK, MAX_TICK, requestedLiquidityAmount);

        test_ReduceTickLimits();

        uint128 posId = LPPosition.getPositionId(
            ACCOUNT_1, initMarketId, initMaturityTimestamp, MIN_TICK, MAX_TICK
        );
        LPPosition.Data memory pos = vamm.position(posId);
        assertEq(pos.liquidity, uint128(requestedLiquidityAmount));

        // BURN IN OUR OF RANGE TICKS
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, MIN_TICK, MAX_TICK, -requestedLiquidityAmount);

        pos = vamm.position(posId);
        assertEq(pos.liquidity, 0);
        assertEq(vamm.tick(), NEW_MIN_TICK + 1);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(NEW_MIN_TICK + 1));
    }

    function test_FirstMint() public returns (int256, int24, int24, uint128) {
        int256 baseAmount =  500_000_000;
        int24 tickLower = -3300;
        int24 tickUpper = -2940;
        uint128 accountId = 738;

        int128 requestedLiquidityAmount = getLiquidityForBase(tickLower, tickUpper, baseAmount);
        // console2.log("REQUESSTED LIQ", requestedLiquidityAmount);
        vamm.executeDatedMakerOrder(accountId, initMarketId, tickLower, tickUpper, requestedLiquidityAmount);

        uint128 posId = LPPosition.getPositionId(
            accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper
        );
        LPPosition.Data memory position = vamm.position(posId);
        assertEq(position.liquidity.toInt(), requestedLiquidityAmount);
        assertEq(position.trackerQuoteTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerQuoteTokenUpdatedGrowth, 0);

        // get global growth 
        // given ticks, check g

        return (baseAmount, tickLower, tickUpper, accountId);
    }

    function test_SecondMint_SameTicks() public {
        (int256 baseAmount, int24 tickLower, int24 tickUpper, uint128 accountId) = test_FirstMint();

        int128 requestedLiquidityAmount = getLiquidityForBase(tickLower, tickUpper, baseAmount);
        vamm.executeDatedMakerOrder(accountId, initMarketId, tickLower, tickUpper, requestedLiquidityAmount);

        uint128 posId = LPPosition.getPositionId(
            accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper
        );
        LPPosition.Data memory position = vamm.position(posId);
        assertEq(position.liquidity.toInt(), requestedLiquidityAmount * 2);
        assertEq(position.trackerQuoteTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerQuoteTokenUpdatedGrowth, 0);
    }

    function test_MintAndSwap_Right_TrackerValue() public {
        test_FirstMint();

        int256 amountSwap =  -1000000;

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: amountSwap,
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MIN_TICK) + 1
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 quoteTokenDelta, int256 baseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(quoteTokenDelta, -2503528, 1e15); // 0.1%
        assertAlmostEqual(baseTokenDelta, 1000000);

        // ((1 + (1.0001 ^ 32223 + 1.0001^32191)/2 / 100 * 1) * 2 * -base) * 2^128 / 916703985467
        // (1 + (midPrice/ 100) * yearsToMaturity) * oracleIndex * -base * Q128 / liquidity = FT delta /liquidity
        int256 expectedTrackerQuoteTokenGrowthGlobalX128 = 930244871434613373462110645841534; // (higher with new formula)
        assertAlmostEqual(vamm.trackerQuoteTokenGrowthGlobalX128(), expectedTrackerQuoteTokenGrowthGlobalX128);
        
        // base * Q128 / liquidity 
        int256 expectedTrackerBaseTokenGrowthGlobalX128 = -371202015389501249169847913412800;
        assertAlmostEqual(vamm.trackerBaseTokenGrowthGlobalX128(), expectedTrackerBaseTokenGrowthGlobalX128);
    }

    function test_ComputeGrowthInsideAfterSwap_NotInitializedTicksBetween() public {
        test_MintAndSwap_Right_TrackerValue();

        // int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -33000;
        int24 tickUpper = -29940;

        (
            int256 _quoteTokenGrowthInsideX128,
            int256 _baseTokenGrowthInsideX128
        ) = vamm.computeGrowthInside(tickLower, tickUpper);
        assertEq(_quoteTokenGrowthInsideX128, vamm.trackerQuoteTokenGrowthGlobalX128());
        assertEq(_baseTokenGrowthInsideX128, vamm.trackerBaseTokenGrowthGlobalX128());
    }

    function test_ComputeGrowthInsideAfterSwap_NotInitializedTicksAbove() public {
        test_MintAndSwap_Right_TrackerValue();

        int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -330;
        int24 tickUpper = -299;

        (
            int256 _quoteTokenGrowthInsideX128,
            int256 _baseTokenGrowthInsideX128
        ) = vamm.computeGrowthInside(tickLower, tickUpper);
        assertEq(_quoteTokenGrowthInsideX128, 0);
        assertEq(_baseTokenGrowthInsideX128, 0);
    }

    function test_updatePositionTokenBalances_NewAndTicksOuside() public {
        test_MintAndSwap_Right_TrackerValue();

        // int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -330;
        int24 tickUpper = -299;
        uint128 accountId = 738;

        LPPosition.Data memory position = vamm.updatePositionTokenBalances(accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper, true);

        assertEq(position.trackerQuoteTokenUpdatedGrowth, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerQuoteTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
    }

    function test_updatePositionTokenBalances_NewAndTicksInside() public {
        test_MintAndSwap_Right_TrackerValue();

        // int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -33300;
        int24 tickUpper = -29999;
        uint128 accountId = 738;

        LPPosition.Data memory position = vamm.updatePositionTokenBalances(accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper, true);

        // console2.log("TICK L G O", vamm.ticks(tickLower).trackerQuoteTokenGrowthOutsideX128);
        // console2.log("TICK U G O", vamm.ticks(tickUpper).trackerQuoteTokenGrowthOutsideX128);
        // console2.log(currentTick);

        assertEq(position.trackerQuoteTokenUpdatedGrowth, vamm.trackerQuoteTokenGrowthGlobalX128());
        assertEq(position.trackerBaseTokenUpdatedGrowth, vamm.trackerBaseTokenGrowthGlobalX128());
        assertEq(position.trackerQuoteTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
    }

    function test_updatePositionTokenBalances_OldAndTicksOutside() public {
        test_MintAndSwap_Right_TrackerValue();

        int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -3300;
        int24 tickUpper = -2940;
        uint128 accountId = 738; // not the 1st mint of this position

        LPPosition.Data memory position = vamm.updatePositionTokenBalances(accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper, true);

        // console2.log("TICK L G O", vamm.ticks(tickLower).trackerQuoteTokenGrowthOutsideX128);
        // console2.log("TICK U G O", vamm.ticks(tickUpper).trackerQuoteTokenGrowthOutsideX128);
        // console2.log(currentTick);

        assertEq(position.trackerQuoteTokenUpdatedGrowth, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerQuoteTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
    }

    //
    function test_updatePositionTokenBalances_OldAndTicksInside() public {
        test_Swap_MovingRight();

        // int24 currentTick = vamm.tick(); // -32137
        //console2.log("CURRENT TICK", currentTick);

        LPPosition.Data memory position = vamm.updatePositionTokenBalances(ACCOUNT_2, initMarketId, initMaturityTimestamp, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, true);

        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerQuoteTokenGrowthOutsideX128); // 0
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerQuoteTokenGrowthOutsideX128); // 0

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128());
        // console2.log("FIXED G GLobal", vamm.trackerQuoteTokenGrowthGlobalX128());
        
        // pos liq 500019035536

        // = growth inside = global - (below + above)
        assertEq(position.trackerQuoteTokenUpdatedGrowth, -462642363410500458711610479230608927);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 185601007694750624584923956706400286);

        // = (growth inside - position.growth) * liquidity / 2^128
        assertEq(position.trackerQuoteTokenAccumulated, -679817736);
        assertEq(position.trackerBaseTokenAccumulated, 272726552);
    }

    function test_SecondMint_TrackPosition() public {
        test_Swap_MovingRight();

        // TL -37945
        // TU -27728
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).initialized, true);

        // int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();
        //console2.log("CURRENT TICK", currentTick);

        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, 1000000);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount, block.timestamp);
        vamm.executeDatedMakerOrder(ACCOUNT_2, initMarketId, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);

        // growth is 0 because ticks were never crossed
        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerQuoteTokenGrowthOutsideX128); // 0
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerQuoteTokenGrowthOutsideX128); // 0

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128());
        // console2.log("FIXED G GLobal", vamm.trackerQuoteTokenGrowthGlobalX128());
        
        // pos liq 500019035536

        // = growth inside = global - (below + above)
        LPPosition.Data memory position = vamm.position(
            LPPosition.getPositionId(ACCOUNT_2, initMarketId, initMaturityTimestamp, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER)
        );
        assertEq(position.trackerQuoteTokenUpdatedGrowth, -462642363410500458711610479230608927);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 185601007694750624584923956706400286);

        // = (growth inside - position.growth) * liquidity / 2^128
        assertEq(position.trackerQuoteTokenAccumulated, -679817736);
        assertEq(position.trackerBaseTokenAccumulated, 272726552);

        assertEq(position.liquidity.toInt(), 500019035536 + requestedLiquidityAmount);

        assertEq(vamm.liquidity().toInt(), vammLiquidityBefore.toInt() + requestedLiquidityAmount);

        // TICKS
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).initialized, true);
        // initialized
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).liquidityGross.toInt(), 500019035536 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).liquidityNet, 500019035536 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityGross.toInt(), 500019035536 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityNet, - 500019035536 - requestedLiquidityAmount);
    }

    function test_MintNewPosSameTicks_AfterTicksCrossed() public {
        test_Swap_MovingMaxRight();

        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).initialized, true);

        // int24 currentTick = vamm.tick(); // -27727
        uint128 vammLiquidityBefore = vamm.liquidity(); // -> 0 all consumed
        // console2.log("CURRENT TICK", currentTick);
        // console2.log("VAMM LIQ BEFORE", vammLiquidityBefore);
        uint128 newAccount = 653;

        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, 1000000);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), newAccount, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount, block.timestamp);
        vamm.executeDatedMakerOrder(newAccount, initMarketId, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        
        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerQuoteTokenGrowthOutsideX128); // 0 -> not crossed
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerQuoteTokenGrowthOutsideX128); // 0 -> -714582490963231596174269836035950460541

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0 -> not crossed
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0 -> 17013179946607015586200609783278514987

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128()); // 17013179946607015586200609783278514987
        // console2.log("FIXED G GLobal", vamm.trackerQuoteTokenGrowthGlobalX128()); // -714582490963231596174269836035950460541
        
        // pos liq 500019035536

        // = growth inside = global - (L G O + GLOBAL - U G O)
        LPPosition.Data memory position = vamm.position(
            LPPosition.getPositionId(newAccount, initMarketId, initMaturityTimestamp, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER)
        );
        console2.log(ACCOUNT_2_TICK_LOWER);
        console2.log(ACCOUNT_2_TICK_UPPER);
        assertEq(position.trackerQuoteTokenUpdatedGrowth, -40730015142572912965292112545422468201);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 17013179946607015586200609783278514987);

        // // = (growth inside - position.growth) * liquidity / 2^128
        assertEq(position.trackerQuoteTokenAccumulated, 0); // only added liq now => no need to update
        assertEq(position.trackerBaseTokenAccumulated, 0); // only added liq now => no need to update

        assertEq(position.liquidity.toInt(), requestedLiquidityAmount);

        assertEq(vamm.liquidity(), vammLiquidityBefore); // ticks outside range => no upadte

        // // TICKS
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).initialized, true);
        // // initialized
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).liquidityGross.toInt(), 500019035536 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).liquidityNet, 500019035536 + requestedLiquidityAmount); // why does liq net don't change
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityGross.toInt(), 500019035536 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityNet, - 500019035536 - requestedLiquidityAmount);
    }

    function test_Burn_TrackPosition() public {
        test_Swap_MovingRight();

        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).initialized, true);

        // int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();

        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, -1000000);
        // console2.log("REQUESTED", requestedLiquidityAmount);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount, block.timestamp);
        vamm.executeDatedMakerOrder(ACCOUNT_2, initMarketId, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);

        // growth is 0 because ticks were never crossed
        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerQuoteTokenGrowthOutsideX128); // 0
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerQuoteTokenGrowthOutsideX128); // 0

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128());
        // console2.log("FIXED G GLobal", vamm.trackerQuoteTokenGrowthGlobalX128());
        
        // pos liq 500019035536

        // = growth inside = global - (below + above)
        LPPosition.Data memory position = vamm.position(
            LPPosition.getPositionId(ACCOUNT_2, initMarketId, initMaturityTimestamp, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER)
        );
        assertEq(position.trackerQuoteTokenUpdatedGrowth, -462642363410500458711610479230608927);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 185601007694750624584923956706400286);

        // = (growth inside - position.growth) * liquidity / 2^128
        assertEq(position.trackerQuoteTokenAccumulated, -679817736);
        assertEq(position.trackerBaseTokenAccumulated, 272726552);

        assertEq(position.liquidity.toInt(), 500019035536 + requestedLiquidityAmount);

        assertEq(vamm.liquidity().toInt(), vammLiquidityBefore.toInt() + requestedLiquidityAmount);

        // TICKS
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).initialized, true);
        // initialized
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).liquidityGross.toInt(), 500019035536 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).liquidityNet, 500019035536 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityGross.toInt(), 500019035536 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityNet, - 500019035536 - requestedLiquidityAmount);
    }

    function test_BurnAll_TrackPosition() public {
        test_Swap_MovingRight();

        assertEq(vamm.ticks(ACCOUNT_1_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_1_TICK_UPPER).initialized, true);

        // int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();

        int128 requestedLiquidityAmount = -getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), ACCOUNT_1, ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount, block.timestamp);
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);

        // growth is 0 because ticks were never crossed
        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerQuoteTokenGrowthOutsideX128); // 0
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerQuoteTokenGrowthOutsideX128); // 0

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128());
        // console2.log("FIXED G GLobal", vamm.trackerQuoteTokenGrowthGlobalX128());
        
        // pos liq 416684949931

        // = growth inside = global - (below + above)
        LPPosition.Data memory position = vamm.position(
            LPPosition.getPositionId(ACCOUNT_1, initMarketId, initMaturityTimestamp, ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER)
        );
        assertEq(position.trackerQuoteTokenUpdatedGrowth, -462642363410500458711610479230608927);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 185601007694750624584923956706400286);

        // = (growth inside - position.growth) * pos.liquidity / 2^128
        assertEq(position.trackerQuoteTokenAccumulated, -566518070);
        assertEq(position.trackerBaseTokenAccumulated, 227273447);

        assertEq(position.liquidity.toInt(), 416684949931 + requestedLiquidityAmount);

        assertEq(vamm.liquidity().toInt(), vammLiquidityBefore.toInt() + requestedLiquidityAmount);

        // TICKS
        assertEq(vamm.ticks(ACCOUNT_1_TICK_LOWER).initialized, false);
        assertEq(vamm.ticks(ACCOUNT_1_TICK_UPPER).initialized, false);
        // initialized                                                    
        assertEq(vamm.ticks(ACCOUNT_1_TICK_LOWER).liquidityGross.toInt(), 416684949931 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_1_TICK_LOWER).liquidityNet, 416684949931 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_1_TICK_UPPER).liquidityGross.toInt(), 416684949931 + requestedLiquidityAmount);
        assertEq(vamm.ticks(ACCOUNT_1_TICK_UPPER).liquidityNet, - 416684949931 - requestedLiquidityAmount);
    }

    function test_RevertWhen_BurnAllFromBothPositions_TrackPosition() public {
        test_Swap_MovingRight();

        assertEq(vamm.ticks(ACCOUNT_1_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_1_TICK_UPPER).initialized, true);

        // int24 currentTick = vamm.tick(); // -32137
        // uint128 vammLiquidityBefore = vamm.liquidity();

        int128 requestedLiquidityAmount1 = -getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
        int128 requestedLiquidityAmount2 = -getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, BASE_AMOUNT_PER_LP);
        // expect event 
        vamm.executeDatedMakerOrder(ACCOUNT_1, initMarketId, ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount1);

        vm.expectRevert(); // Arithmetic over/underflow
        vamm.executeDatedMakerOrder(ACCOUNT_2, initMarketId, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount2 - 1);

        vamm.executeDatedMakerOrder(ACCOUNT_2, initMarketId, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount2);

        assertEq(vamm.liquidity().toInt(), 0);
        // console2.log("Tick after", vamm.tick()); // -32137
        // console2.log("Liquidity after", vamm.liquidity());
    }

    function test_RevertWhen_MintAfterNoLiquidity_TrackPosition() public {
        test_RevertWhen_BurnAllFromBothPositions_TrackPosition();

        // Test swap to right
        {
            int256 amountSpecified =  1;
            DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MAX_TICK - 1)
            });
            
            vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
            (int256 quoteTokenDelta, int256 baseTokenDelta) = vamm.vammSwap(params);
            assertAlmostEqual(baseTokenDelta, 0);
            assertAlmostEqual(quoteTokenDelta, 0);
            assertEq(vamm.tick(), MAX_TICK - 1);
            assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(MAX_TICK - 1));
        }

        // Test swap to left
        {
            int256 amountSpecified =  -1;
            DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MIN_TICK + 1)
            });
            
            vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
            (int256 quoteTokenDelta, int256 baseTokenDelta) = vamm.vammSwap(params);
            assertAlmostEqual(baseTokenDelta, 0);
            assertAlmostEqual(quoteTokenDelta, 0);
            assertEq(vamm.tick(), MIN_TICK + 1);
            assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(MIN_TICK + 1));
        }
    }

    function test_UnwindLPFull_TrackPosition() public {
        test_Swap_MovingRight();

        // int24 currentTick = vamm.tick(); // -32137
        // uint128 vammLiquidityBefore = vamm.liquidity();

        // (int256 baseBalancePool0, int256 quoteBalancePool0) = 
        vamm.getAccountFilledBalances(ACCOUNT_2);
        // console2.log("baseBalancePool", baseBalancePool0);
        // console2.log("quoteBalancePool", quoteBalancePool0);

        int128 requestedLiquidityAmount = -getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, BASE_AMOUNT_PER_LP);
        // console2.log("REQUESTED", requestedLiquidityAmount);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount, block.timestamp);
        vamm.executeDatedMakerOrder(ACCOUNT_2, initMarketId, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);

        // CLOSE FILLED BALANCES
        (int256 baseBalancePool,) = vamm.getAccountFilledBalances(ACCOUNT_2);
        // console2.log("baseBalancePool", baseBalancePool);
        // console2.log("quoteBalancePool", quoteBalancePool);

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: baseBalancePool, 
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MAX_TICK - 1)
        });
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (, int256 baseTokenDelta) = vamm.vammSwap(params);
        // console2.log("quoteTokenDelta", quoteTokenDelta);
        // console2.log("baseTokenDelta", baseTokenDelta);
        assertEq(baseTokenDelta, -baseBalancePool);

        // CHECK UNFILLED BALANCES = 0
        LPPosition.Data memory position = vamm.position(LPPosition.getPositionId(
            ACCOUNT_2, initMarketId, initMaturityTimestamp, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER
        ));
        assertEq(position.liquidity.toInt(), 0);

        (uint256 unfilledBaseLong, uint256 unfilledBaseShort,,) = vamm.getAccountUnfilledBalances(ACCOUNT_2);
        assertEq(unfilledBaseLong.toInt(), 0);
        assertEq(unfilledBaseShort.toInt(), 0);
    }

    function test_UnwindLPPartial_TrackPosition() public {
        test_Swap_MovingRight();

        // int24 currentTick = vamm.tick(); // -32137
        // uint128 vammLiquidityBefore = vamm.liquidity();

        // CLOSE FILLED BALANCES
        (int256 baseBalancePool,) = vamm.getAccountFilledBalances(ACCOUNT_2);

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: baseBalancePool, 
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(MAX_TICK - 1)
        });
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex.add(UNIT)));
        (, int256 baseTokenDelta) = vamm.vammSwap(params);
        assertEq(baseTokenDelta, -baseBalancePool);
    }

    function test_GetFilledBalancesAfterMaturiy() public {
        test_Swap_MovingRight();

        (int256 baseBalancePoolBefore, int256 quoteBalancePoolBefore) = vamm.getAccountFilledBalances(ACCOUNT_2);

        vm.warp(initMaturityTimestamp + 1);

        (int256 baseBalancePoolAfter,) = vamm.getAccountFilledBalances(ACCOUNT_2);
        assertEq(baseBalancePoolBefore, baseBalancePoolAfter);
        assertEq(quoteBalancePoolBefore, quoteBalancePoolBefore);
    }

    // account 1 entered before the swap, account 3 entered after the swap
    function test_GetFilledBalancesAfterMaturiy_TwoAccountsSamePosition() public {
        test_Swap_MovingRight();

        (int256 account1BaseBalancePoolBefore, int256 account1QuoteBalancePoolBefore) = vamm.getAccountFilledBalances(ACCOUNT_2);

        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, 3);
        vamm.executeDatedMakerOrder(3, initMarketId, ACCOUNT_1_TICK_LOWER,ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);

        (int256 account3BaseBalancePoolBefore,) = vamm.getAccountFilledBalances(3);

        vm.warp(initMaturityTimestamp + 1);

        (int256 account1BaseBalancePoolAfter, int256 account1QuoteBalancePoolAfter) = vamm.getAccountFilledBalances(ACCOUNT_2);
        assertEq(account1BaseBalancePoolBefore, account1BaseBalancePoolAfter);
        assertEq(account1QuoteBalancePoolBefore, account1QuoteBalancePoolAfter);

        (, int256 account3QuoteBalancePoolAfter) = vamm.getAccountFilledBalances(3);
        assertEq(account3BaseBalancePoolBefore, 0);
        assertEq(account3QuoteBalancePoolAfter, 0);
    }
}