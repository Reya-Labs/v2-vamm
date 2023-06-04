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

    function setUp() public {

        vammId = uint256(keccak256(abi.encodePacked(initMarketId, uint32(initMaturityTimestamp))));
        vamm = new ExposedDatedIrsVamm(vammId);
        vamm.create(initMarketId, initSqrtPriceX96, immutableConfig, mutableConfig);

        // console2.log("requestedBaseAmount (per LP)  ", BASE_AMOUNT_PER_LP);

        {
            // LP 1
            int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
            vamm.executeDatedMakerOrder(ACCOUNT_1,ACCOUNT_1_TICK_LOWER,ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);
        }
        {
            // LP 2
            int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, BASE_AMOUNT_PER_LP);
            vamm.executeDatedMakerOrder(ACCOUNT_2,ACCOUNT_2_TICK_LOWER,ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        }

        // We know that the current price is within the range of both LPs, so to calculate base tokens available to trade to the left we add:
        //    liquidity * distance_from_current_price_to_LP2_lower_tick
        // AND
        //    LP1_liquidity_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        baseTradeableToLeft += VAMMBase.baseBetweenTicks(ACCOUNT_2_TICK_LOWER, vamm.tick(), vamm.liquidity().toInt());
        baseTradeableToLeft += VAMMBase.baseBetweenTicks(ACCOUNT_1_TICK_LOWER, ACCOUNT_2_TICK_LOWER, vamm.ticks( ACCOUNT_1_TICK_LOWER).liquidityNet);
        // console2.log("baseTradeableToLeft  ", baseTradeableToLeft);

        // We know that the current price is within the range of both LPs, so to calculate base tokens available to trade to the right we add:
        //    liquidity * distance_from_current_price_to_LP1_upper_tick
        // AND
        //    LP2_per-tick_value * distance_from_LP1_lower_tick_to_LP2_lower_tick
        baseTradeableToRight += VAMMBase.baseBetweenTicks(vamm.tick(), ACCOUNT_1_TICK_UPPER, vamm.liquidity().toInt());
        baseTradeableToRight += VAMMBase.baseBetweenTicks(ACCOUNT_1_TICK_UPPER, ACCOUNT_2_TICK_UPPER, -vamm.ticks(ACCOUNT_2_TICK_UPPER).liquidityNet);
        // console2.log("baseTradeableToRight ", baseTradeableToRight);
    }

    function test_TradeableBaseTokens() public {
        assertAlmostEqual(BASE_AMOUNT_PER_LP * 2, baseTradeableToLeft + baseTradeableToRight);
    }

    function test_CorrectCreation() public {
        assertEq(vamm.tick(), TickMath.getTickAtSqrtRatio(initSqrtPriceX96));
    }

    function test_GetAccountUnfilledBases() public {
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

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: ACCOUNT_2_UPPER_SQRTPRICEX96
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);
        // console2.log("SWAP 1 FT D", trackerFixedTokenDelta);
        // console2.log("SWAP 1 BT D", trackerBaseTokenDelta);

        assertAlmostEqual(trackerBaseTokenDelta, -amountSpecified);
    }

    function test_Swap_MovingLeft() public {
        int256 amountSpecified =  -500_000_000;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK + 1)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, -amountSpecified);
    }

    function test_Swap_MovingMaxRight() public {
        int24 tickLimit = ACCOUNT_2_TICK_UPPER + 1;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: 500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToRight
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, -baseTradeableToRight);
        assertEq(vamm.tick(), tickLimit);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit));
    }

    function test_Swap_MovingMaxLeft() public {
        int24 tickLimit = TickMath.MIN_TICK + 1;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: -500_000_000_000_000_000_000_000_000_000_000, // There is not enough liquidity - swap should max out at baseTradeableToLeft
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(tickLimit)
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));

        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerBaseTokenDelta, baseTradeableToLeft);
        assertEq(vamm.tick(), tickLimit);
        assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(tickLimit));
    }

    function test_FirstMint() public returns (int256, int24, int24, uint128) {
        int256 baseAmount =  500_000_000;
        int24 tickLower = -3300;
        int24 tickUpper = -2940;
        uint128 accountId = 738;

        int128 requestedLiquidityAmount = getLiquidityForBase(tickLower, tickUpper, baseAmount);
        // console2.log("REQUESSTED LIQ", requestedLiquidityAmount);
        vamm.executeDatedMakerOrder(accountId, tickLower, tickUpper, requestedLiquidityAmount);

        uint128 posId = LPPosition.getPositionId(accountId, tickLower, tickUpper);
        LPPosition.Data memory position = vamm.position(posId);
        assertEq(position.liquidity.toInt(), requestedLiquidityAmount);
        assertEq(position.trackerFixedTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerFixedTokenUpdatedGrowth, 0);

        // get global growth 
        // given ticks, check g

        return (baseAmount, tickLower, tickUpper, accountId);
    }

    function test_SecondMint_SameTicks() public {
        (int256 baseAmount, int24 tickLower, int24 tickUpper, uint128 accountId) = test_FirstMint();

        int128 requestedLiquidityAmount = getLiquidityForBase(tickLower, tickUpper, baseAmount);
        vamm.executeDatedMakerOrder(accountId, tickLower, tickUpper, requestedLiquidityAmount);

        uint128 posId = LPPosition.getPositionId(accountId, tickLower, tickUpper);
        LPPosition.Data memory position = vamm.position(posId);
        assertEq(position.liquidity.toInt(), requestedLiquidityAmount * 2);
        assertEq(position.trackerFixedTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerFixedTokenUpdatedGrowth, 0);
    }

    function test_MintAndSwap_Right_TrackerValue() public {
        (int256 baseAmount, int24 tickLower, int24 tickUpper, uint128 accountId) = test_FirstMint();

        int256 amountSwap =  -1000000;

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: amountSwap,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
        });

        // Mock the liquidity index that is read during a swap
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);

        assertAlmostEqual(trackerFixedTokenDelta, -52160000, 1e15); // 0.1%
        assertAlmostEqual(trackerBaseTokenDelta, 1000000);

        // ((1 + (1.0001 ^ 32223 + 1.0001^32191)/2 * 1) * 2 * -base) * 2^128 / 916703985467
        // (1 + (midPrice) * yearsToMaturity) * oracleIndex * -base * Q128 / liquidity = FT delta /liquidity
        int256 expectedTrackerFixedTokenGrowthGlobalX128 = 19364050094405644263944452281509472;
        assertAlmostEqual(vamm.trackerFixedTokenGrowthGlobalX128(), expectedTrackerFixedTokenGrowthGlobalX128);
        
        // base * Q128 / liquidity 
        int256 expectedTrackerBaseTokenGrowthGlobalX128 = -371202015389501249169847913412800;
        assertAlmostEqual(vamm.trackerBaseTokenGrowthGlobalX128(), expectedTrackerBaseTokenGrowthGlobalX128);
    }

    function test_ComputeGrowthInsideAfterSwap_NotInitializedTicksBetween() public {
        test_MintAndSwap_Right_TrackerValue();

        int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -33000;
        int24 tickUpper = -29940;

        (
            int256 _fixedTokenGrowthInsideX128,
            int256 _baseTokenGrowthInsideX128
        ) = vamm.computeGrowthInside(tickLower, tickUpper);
        assertEq(_fixedTokenGrowthInsideX128, vamm.trackerFixedTokenGrowthGlobalX128());
        assertEq(_baseTokenGrowthInsideX128, vamm.trackerBaseTokenGrowthGlobalX128());
    }

    function test_ComputeGrowthInsideAfterSwap_NotInitializedTicksAbove() public {
        test_MintAndSwap_Right_TrackerValue();

        int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -330;
        int24 tickUpper = -299;

        (
            int256 _fixedTokenGrowthInsideX128,
            int256 _baseTokenGrowthInsideX128
        ) = vamm.computeGrowthInside(tickLower, tickUpper);
        assertEq(_fixedTokenGrowthInsideX128, 0);
        assertEq(_baseTokenGrowthInsideX128, 0);
    }

    function test_updatePositionTokenBalances_NewAndTicksOuside() public {
        test_MintAndSwap_Right_TrackerValue();

        int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -330;
        int24 tickUpper = -299;
        uint128 accountId = 738;

        LPPosition.Data memory position = vamm.updatePositionTokenBalances(accountId, tickLower, tickUpper, true);

        assertEq(position.trackerFixedTokenUpdatedGrowth, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerFixedTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
    }

    function test_updatePositionTokenBalances_NewAndTicksInside() public {
        test_MintAndSwap_Right_TrackerValue();

        int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -33300;
        int24 tickUpper = -29999;
        uint128 accountId = 738;

        LPPosition.Data memory position = vamm.updatePositionTokenBalances(accountId, tickLower, tickUpper, true);

        // console2.log("TICK L G O", vamm.ticks(tickLower).trackerFixedTokenGrowthOutsideX128);
        // console2.log("TICK U G O", vamm.ticks(tickUpper).trackerFixedTokenGrowthOutsideX128);
        // console2.log(currentTick);

        assertEq(position.trackerFixedTokenUpdatedGrowth, vamm.trackerFixedTokenGrowthGlobalX128());
        assertEq(position.trackerBaseTokenUpdatedGrowth, vamm.trackerBaseTokenGrowthGlobalX128());
        assertEq(position.trackerFixedTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
    }

    function test_updatePositionTokenBalances_OldAndTicksOutside() public {
        test_MintAndSwap_Right_TrackerValue();

        int24 currentTick = vamm.tick(); // -32192

        int24 tickLower = -3300;
        int24 tickUpper = -2940;
        uint128 accountId = 738; // not the 1st mint of this position

        LPPosition.Data memory position = vamm.updatePositionTokenBalances(accountId, tickLower, tickUpper, true);

        // console2.log("TICK L G O", vamm.ticks(tickLower).trackerFixedTokenGrowthOutsideX128);
        // console2.log("TICK U G O", vamm.ticks(tickUpper).trackerFixedTokenGrowthOutsideX128);
        // console2.log(currentTick);

        assertEq(position.trackerFixedTokenUpdatedGrowth, 0);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 0);
        assertEq(position.trackerFixedTokenAccumulated, 0);
        assertEq(position.trackerBaseTokenAccumulated, 0);
    }

    function test_updatePositionTokenBalances_OldAndTicksInside() public {
        test_Swap_MovingRight();

        int24 currentTick = vamm.tick(); // -32137
        //console2.log("CURRENT TICK", currentTick);

        LPPosition.Data memory position = vamm.updatePositionTokenBalances(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, true);

        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerFixedTokenGrowthOutsideX128); // 0
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerFixedTokenGrowthOutsideX128); // 0

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128());
        // console2.log("FIXED G GLobal", vamm.trackerFixedTokenGrowthGlobalX128());
        
        // pos liq 500019035536

        // = growth inside = global - (below + above)
        assertEq(position.trackerFixedTokenUpdatedGrowth, -9564234701398189942557392418894572033);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 185601007694750624584923956706400286);

        // = (growth inside - position.growth) * liquidity / 2^128
        assertEq(position.trackerFixedTokenAccumulated, -14053914854);
        assertEq(position.trackerBaseTokenAccumulated, 272726552);
    }

    function test_SecondMint_TrackPosition() public {
        test_Swap_MovingRight();

        // TL -37945
        // TU -27728
        assertEq(vamm.ticks(ACCOUNT_2_TICK_LOWER).initialized, true);
        assertEq(vamm.ticks(ACCOUNT_2_TICK_UPPER).initialized, true);

        int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();
        //console2.log("CURRENT TICK", currentTick);

        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, 1000000);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        vamm.executeDatedMakerOrder(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);

        // growth is 0 because ticks were never crossed
        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerFixedTokenGrowthOutsideX128); // 0
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerFixedTokenGrowthOutsideX128); // 0

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128());
        // console2.log("FIXED G GLobal", vamm.trackerFixedTokenGrowthGlobalX128());
        
        // pos liq 500019035536

        // = growth inside = global - (below + above)
        LPPosition.Data memory position = vamm.position(LPPosition.getPositionId(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER));
        assertEq(position.trackerFixedTokenUpdatedGrowth, -9564234701398189942557392418894572033);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 185601007694750624584923956706400286);

        // = (growth inside - position.growth) * liquidity / 2^128
        assertEq(position.trackerFixedTokenAccumulated, -14053914854);
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

        int24 currentTick = vamm.tick(); // -27727
        uint128 vammLiquidityBefore = vamm.liquidity(); // -> 0 all consumed
        // console2.log("CURRENT TICK", currentTick);
        // console2.log("VAMM LIQ BEFORE", vammLiquidityBefore);
        uint128 newAccount = 653;

        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, 1000000);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), newAccount, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        vamm.executeDatedMakerOrder(newAccount, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        
        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerFixedTokenGrowthOutsideX128); // 0 -> not crossed
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerFixedTokenGrowthOutsideX128); // 0 -> -714582490963231596174269836035950460541

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0 -> not crossed
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0 -> 17013179946607015586200609783278514987

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128()); // 17013179946607015586200609783278514987
        // console2.log("FIXED G GLobal", vamm.trackerFixedTokenGrowthGlobalX128()); // -714582490963231596174269836035950460541
        
        // pos liq 500019035536

        // = growth inside = global - (L G O + GLOBAL - U G O)
        LPPosition.Data memory position = vamm.position(LPPosition.getPositionId(newAccount, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER));
        assertEq(position.trackerFixedTokenUpdatedGrowth, -714617096729198643702920601548795967095);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 17013179946607015586200609783278514987);

        // // = (growth inside - position.growth) * liquidity / 2^128
        assertEq(position.trackerFixedTokenAccumulated, 0); // only added liq now => no need to update
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

        int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();

        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, -1000000);
        // console2.log("REQUESTED", requestedLiquidityAmount);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        vamm.executeDatedMakerOrder(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);

        // growth is 0 because ticks were never crossed
        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerFixedTokenGrowthOutsideX128); // 0
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerFixedTokenGrowthOutsideX128); // 0

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128());
        // console2.log("FIXED G GLobal", vamm.trackerFixedTokenGrowthGlobalX128());
        
        // pos liq 500019035536

        // = growth inside = global - (below + above)
        LPPosition.Data memory position = vamm.position(LPPosition.getPositionId(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER));
        assertEq(position.trackerFixedTokenUpdatedGrowth, -9564234701398189942557392418894572033);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 185601007694750624584923956706400286);

        // = (growth inside - position.growth) * liquidity / 2^128
        assertEq(position.trackerFixedTokenAccumulated, -14053914854);
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

        int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();

        int128 requestedLiquidityAmount = -getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), ACCOUNT_1, ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);
        vamm.executeDatedMakerOrder(ACCOUNT_1, ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);

        // growth is 0 because ticks were never crossed
        // console2.log("TICK L G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerFixedTokenGrowthOutsideX128); // 0
        // console2.log("TICK U G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerFixedTokenGrowthOutsideX128); // 0

        // console2.log("TICK L BASE G O", vamm.ticks(ACCOUNT_2_TICK_LOWER).trackerBaseTokenGrowthOutsideX128); // 0
        // console2.log("TICK U BASE G O", vamm.ticks(ACCOUNT_2_TICK_UPPER).trackerBaseTokenGrowthOutsideX128); // 0

        // console2.log("BASE G GLobal", vamm.trackerBaseTokenGrowthGlobalX128());
        // console2.log("FIXED G GLobal", vamm.trackerFixedTokenGrowthGlobalX128());
        
        // pos liq 416684949931

        // = growth inside = global - (below + above)
        LPPosition.Data memory position = vamm.position(LPPosition.getPositionId(ACCOUNT_1, ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER));
        assertEq(position.trackerFixedTokenUpdatedGrowth, -9564234701398189942557392418894572033);
        assertEq(position.trackerBaseTokenUpdatedGrowth, 185601007694750624584923956706400286);

        // = (growth inside - position.growth) * pos.liquidity / 2^128
        assertEq(position.trackerFixedTokenAccumulated, -11711663738);
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

        int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();

        int128 requestedLiquidityAmount1 = -getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
        int128 requestedLiquidityAmount2 = -getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, BASE_AMOUNT_PER_LP);
        // expect event 
        vamm.executeDatedMakerOrder(ACCOUNT_1, ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount1);

        vm.expectRevert(); // Arithmetic over/underflow
        vamm.executeDatedMakerOrder(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount2 - 1);

        vamm.executeDatedMakerOrder(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount2);

        assertEq(vamm.liquidity().toInt(), 0);
        // console2.log("Tick after", vamm.tick()); // -32137
        // console2.log("Liquidity after", vamm.liquidity());
    }

    function test_RevertWhen_MintAfterNoLiquidity_TrackPosition() public {
        test_RevertWhen_BurnAllFromBothPositions_TrackPosition();

        // Test swap to right
        {
            int256 amountSpecified =  1;
            VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK - 1)
            });
            
            vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
            (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);
            assertAlmostEqual(trackerBaseTokenDelta, 0);
            assertAlmostEqual(trackerFixedTokenDelta, 0);
            assertEq(vamm.tick(), TickMath.MAX_TICK - 1);
            assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK - 1));
        }

        // Test swap to left
        {
            int256 amountSpecified =  -1;
            VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK + 1)
            });
            
            vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
            (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);
            assertAlmostEqual(trackerBaseTokenDelta, 0);
            assertAlmostEqual(trackerFixedTokenDelta, 0);
            assertEq(vamm.tick(), TickMath.MIN_TICK + 1);
            assertEq(vamm.sqrtPriceX96(), TickMath.getSqrtRatioAtTick(TickMath.MIN_TICK + 1));
        }
    }

    function test_UnwindLPFull_TrackPosition() public {
        test_Swap_MovingRight();

        int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();

        (int256 baseBalancePool0, int256 quoteBalancePool0) = vamm.getAccountFilledBalances(ACCOUNT_2);
        // console2.log("baseBalancePool", baseBalancePool0);
        // console2.log("quoteBalancePool", quoteBalancePool0);

        int128 requestedLiquidityAmount = -getLiquidityForBase(ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, BASE_AMOUNT_PER_LP);
        // console2.log("REQUESTED", requestedLiquidityAmount);
        // expect event 
        vm.expectEmit(true, true, false, true);
        emit VAMMBase.LiquidityChange(initMarketId, uint32(initMaturityTimestamp), address(this), ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);
        vamm.executeDatedMakerOrder(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER, requestedLiquidityAmount);

        // CLOSE FILLED BALANCES
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(ACCOUNT_2);
        // console2.log("baseBalancePool", baseBalancePool);
        // console2.log("quoteBalancePool", quoteBalancePool);

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: baseBalancePool, 
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK - 1)
        });
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);
        // console2.log("trackerFixedTokenDelta", trackerFixedTokenDelta);
        // console2.log("trackerBaseTokenDelta", trackerBaseTokenDelta);
        assertEq(trackerBaseTokenDelta, -baseBalancePool);

        // CHECK UNFILLED BALANCES = 0
        LPPosition.Data memory position = vamm.position(LPPosition.getPositionId(ACCOUNT_2, ACCOUNT_2_TICK_LOWER, ACCOUNT_2_TICK_UPPER));
        assertEq(position.liquidity.toInt(), 0);

        (uint256 unfilledBaseLong, uint256 unfilledBaseShort) = vamm.getAccountUnfilledBases(ACCOUNT_2);
        assertEq(unfilledBaseLong.toInt(), 0);
        assertEq(unfilledBaseShort.toInt(), 0);
    }

    function test_UnwindLPPartial_TrackPosition() public {
        test_Swap_MovingRight();

        int24 currentTick = vamm.tick(); // -32137
        uint128 vammLiquidityBefore = vamm.liquidity();

        // CLOSE FILLED BALANCES
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(ACCOUNT_2);

        VAMMBase.SwapParams memory params = VAMMBase.SwapParams({
            amountSpecified: baseBalancePool, 
            sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(TickMath.MAX_TICK - 1)
        });
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex.add(UNIT)));
        (int256 trackerFixedTokenDelta, int256 trackerBaseTokenDelta) = vamm.vammSwap(params);
        assertEq(trackerBaseTokenDelta, -baseBalancePool);
    }

    function test_GetFilledBalancesAfterMaturiy() public {
        test_Swap_MovingRight();

        (int256 baseBalancePoolBefore, int256 quoteBalancePoolBefore) = vamm.getAccountFilledBalances(ACCOUNT_2);

        vm.warp(initMaturityTimestamp + 1);

        (int256 baseBalancePoolAfter, int256 quoteBalancePoolAfter) = vamm.getAccountFilledBalances(ACCOUNT_2);
        assertEq(baseBalancePoolBefore, baseBalancePoolAfter);
        assertEq(quoteBalancePoolBefore, quoteBalancePoolBefore);
    }

    // account 1 entered before the swap, account 3 entered after the swap
    function test_GetFilledBalancesAfterMaturiy_TwoAccountsSamePosition() public {
        test_Swap_MovingRight();

        (int256 account1BaseBalancePoolBefore, int256 account1QuoteBalancePoolBefore) = vamm.getAccountFilledBalances(ACCOUNT_2);

        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, 3);
        vamm.executeDatedMakerOrder(3,ACCOUNT_1_TICK_LOWER,ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);

        (int256 account3BaseBalancePoolBefore, int256 account3QuoteBalancePoolBefore) = vamm.getAccountFilledBalances(3);

        vm.warp(initMaturityTimestamp + 1);

        (int256 account1BaseBalancePoolAfter, int256 account1QuoteBalancePoolAfter) = vamm.getAccountFilledBalances(ACCOUNT_2);
        assertEq(account1BaseBalancePoolBefore, account1BaseBalancePoolAfter);
        assertEq(account1QuoteBalancePoolBefore, account1QuoteBalancePoolAfter);

        (int256 account3BaseBalancePoolAfter, int256 account3QuoteBalancePoolAfter) = vamm.getAccountFilledBalances(3);
        assertEq(account3BaseBalancePoolBefore, 0);
        assertEq(account3QuoteBalancePoolAfter, 0);
    }
}