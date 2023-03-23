pragma solidity >=0.8.13;

import "forge-std/Test.sol";
 import "forge-std/console2.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/src/UD60x18.sol";
import { SD59x18 } from "@prb/math/src/SD59x18.sol";

// Asserts - TODO: move into own source file

contract VoltzAssertions is Test {

    function assertEq(UD60x18 a, UD60x18 b) internal {
        assertEq(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertGt(UD60x18 a, UD60x18 b) internal {
        assertGt(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertLt(UD60x18 a, UD60x18 b) internal {
        assertLt(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertAlmostEqual(UD60x18 a, UD60x18 b, UD60x18 deltaAsFractionOfA) internal {
        UD60x18 upperBound = a.add(deltaAsFractionOfA.mul(a));
        UD60x18 lowerBound = a.sub(deltaAsFractionOfA.mul(a));
        if (b.gt(upperBound) || b.lt(lowerBound)) {
            console.log("Expected %s <= %s <= %s", UD60x18.unwrap(lowerBound), UD60x18.unwrap(b), UD60x18.unwrap(upperBound));
        }
        assertGe(UD60x18.unwrap(b), UD60x18.unwrap(lowerBound) );
        assertLe(UD60x18.unwrap(b), UD60x18.unwrap(upperBound) );
    }
    function assertAlmostEqual(UD60x18 a, UD60x18 b) internal {
        UD60x18 deltaAsFractionOfA = ud60x18(1e14); // 0.01%
        assertAlmostEqual(a, b, deltaAsFractionOfA);
    }
    function assertEq(UD60x18 a, UD60x18 b, string memory err) internal {
        assertEq(UD60x18.unwrap(a), UD60x18.unwrap(b), err);
    }
    function boundTicks(
        int24 _tickLower,
        int24 _tickUpper)
    internal returns (int24 tickLower, int24 tickUpper)
    {
        // Ticks must be in range and cannot be equal
        tickLower = int24(bound(_tickLower,  TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        tickUpper = int24(bound(_tickUpper,  TickMath.MIN_TICK + 1, TickMath.MAX_TICK));
        vm.assume(tickLower < tickUpper);
    }
}

// Helpers
function abs(int256 x) pure returns (uint256) {
    return x >= 0 ? uint256(x) : uint256(-x);
}

// Constants
UD60x18 constant ONE = UD60x18.wrap(1e18);

contract ExposedDatedIrsVamm {

    // Exposed functions
    function getAverageBase(
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount
    ) external pure returns(int128) {
        return DatedIrsVamm.getAverageBase(tickLower, tickUpper, baseAmount);
    }
}

contract VammTest is VoltzAssertions {
    // Contracts under test
    using DatedIrsVamm for DatedIrsVamm.Data;
    DatedIrsVamm.Data internal vamm;
    ExposedDatedIrsVamm exposedVamm;

    address constant mockRateOracle = 0xAa73aA73Aa73Aa73AA73Aa73aA73AA73aa73aa73;

    // Test state
    // uint256 latestPositionId;

    // Initial VAMM state
    uint160 initSqrtPriceX96 = uint160(2 * FixedPoint96.Q96 / 10); // 0.2 => price ~= 0.04 = 4%
    uint128 initMarketId = 1;
    int24 initTickSpacing = 1000;
    DatedIrsVamm.Config internal config = DatedIrsVamm.Config({
        priceImpactPhi: ud60x18(1e17), // 0.1
        priceImpactBeta: ud60x18(125e15), // 0.125
        spread: ud60x18(3e15), // 0.3%
        rateOracle: IRateOracle(mockRateOracle)
    });

    function setUp() public {
        exposedVamm = new ExposedDatedIrsVamm();
        vamm.initialize(initSqrtPriceX96, block.timestamp + 100, initMarketId, initTickSpacing, config);
    }

    function test_Init_State() public {
        assertEq(vamm._vammVars.sqrtPriceX96, initSqrtPriceX96); 
        assertEq(vamm._vammVars.tick, TickMath.getTickAtSqrtRatio(initSqrtPriceX96)); 
        assertEq(vamm._vammVars.observationIndex, 0); 
        assertEq(vamm._vammVars.observationCardinality, 1); 
        assertEq(vamm._vammVars.observationCardinalityNext, 1); 
        assertEq(vamm._vammVars.feeProtocol, 0); 
        assertEq(vamm._vammVars.unlocked, true); 
        assertEq(vamm.config.priceImpactPhi, config.priceImpactPhi); 
        assertEq(vamm.config.priceImpactBeta, config.priceImpactBeta); 
        assertEq(vamm.config.spread, config.spread); 
        assertEq(address(vamm.config.rateOracle), address(config.rateOracle)); 
    }

    function test_Init_Twap_Unadjusted() public {
        int24 tick = vamm._vammVars.tick;
        assertEq(vamm.observe(0), tick); 

        // no lookback, no adjustments
        UD60x18 geometricMeanPrice = vamm.twap(0, 0, false, false);
        assertEq(geometricMeanPrice, DatedIrsVamm.getPriceFromTick(tick)); 
        assertAlmostEqual(geometricMeanPrice, ud60x18(4e16)); // Approx 0.04. Not exact cos snaps to tick boundary.
    }

    function test_Init_Twap_WithSpread() public {
        int24 tick = vamm._vammVars.tick;
        assertEq(vamm.observe(0), tick); 

        {
            // no lookback, adjust for spread, positive order size
            UD60x18 twapPrice = vamm.twap(0, 1, false, true);
            // Spread adds 0.3% to the price (as an absolute amount, not as a percentage of the price)
            assertEq(twapPrice, DatedIrsVamm.getPriceFromTick(tick).add(config.spread)); 
        }

        {
            // no lookback, adjust for spread, negative order size
            UD60x18 twapPrice = vamm.twap(0, -1, false, true);
            // Spread subtracts 0.3% from the price (as an absolute amount, not as a percentage of the price)
            assertEq(twapPrice, DatedIrsVamm.getPriceFromTick(tick).sub(config.spread));
        }
    }

    function test_Init_Twap_WithPriceImpact() public {
        int24 tick = vamm._vammVars.tick;
        assertEq(vamm.observe(0), tick); 

        {
            // no lookback, adjust for price impact of positive orderSize 100000000
            int256 orderSize = 100000000;
            UD60x18 twapPrice = vamm.twap(0, orderSize, true, false);

            // Price impact adds a multiple of 0.1*orderSize^0.125
            //                               = 0.1*100000000^0.125
            //                               = 0.1*10 = 1 to the price, i.e. doubles the price
            assertAlmostEqual(twapPrice, DatedIrsVamm.getPriceFromTick(tick).mul(ONE.add(ONE)));  
        }

        {
            // no lookback, adjust for price impact of negative orderSize 256
            int256 orderSize = -256;
            UD60x18 twapPrice = vamm.twap(0, orderSize, true, false);

            // Price impact subtracts a multiple of 0.1*abs(orderSize)^0.125
            //                               = 0.1*256^0.125
            //                               = 0.1*2 = 0.2 times the price, i.e. takes 20% off the price
            assertAlmostEqual(twapPrice, DatedIrsVamm.getPriceFromTick(tick).mul(ud60x18(8e17)));  
        }
    }

    /// @dev Useful check that we do not crash (e.g. due to underflow) while making adjustments to TWAP output
    function testFuzz_Init_Twap(int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread) public {
        vm.assume(orderSize != 0);
        orderSize = bound(orderSize, -int256(uMAX_UD60x18 / uUNIT), int256(uMAX_UD60x18 / uUNIT));

        int24 tick = vamm._vammVars.tick;
        assertEq(vamm.observe(0), tick);
        UD60x18 instantPrice = DatedIrsVamm.getPriceFromTick(tick);

        // no lookback
        UD60x18 twapPrice = vamm.twap(0, orderSize, adjustForPriceImpact, adjustForSpread);

        if (!adjustForPriceImpact && !adjustForSpread) {
            assertEq(twapPrice, instantPrice); 
        } else if (orderSize < 0) {
             assertLt(twapPrice, instantPrice); 
        } else {
             assertGt(twapPrice, instantPrice); 
        }
    }

    function testFuzz_GetAverageBase(
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount)
    public {
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);
        assertEq(exposedVamm.getAverageBase(tickLower, tickUpper, baseAmount), baseAmount / (tickUpper - tickLower));
    }

    function testFail_GetUnopenedPosition() public {
        vamm.getRawPosition(1);
    }

    function testFuzz_GetAccountFilledBalancesUnusedAccount(uint128 accountId) public {
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    }

    function testFuzz_GetAccountUnfilledBasesUnusedAccount(uint128 accountId) public {
        (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        assertEq(unfilledBaseLong, 0);
        assertEq(unfilledBaseShort, 0);
    }

    function openPosition(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper)
    internal
    returns (uint256 positionId, DatedIrsVamm.LPPosition memory position)
    {
        positionId = vamm.openPosition(accountId,tickLower,tickUpper);
        position = vamm.positions[positionId];
    }

    function testFuzz_OpenPosition(uint128 accountId, int24 tickLower, int24 tickUpper) public {
        vm.assume(accountId != 0);
        (tickLower, tickUpper) = boundTicks(tickLower, tickUpper);

        (uint256 positionId, DatedIrsVamm.LPPosition memory p) = openPosition(accountId,tickLower,tickUpper);
        assertEq(positionId, DatedIrsVamm.getPositionId(accountId,tickLower,tickUpper));
        assertEq(p.accountId, accountId);
        assertEq(p.tickLower, tickLower);
        assertEq(p.tickUpper, tickUpper);
        assertEq(p.baseAmount, 0);
        assertEq(p.tracker0UpdatedGrowth, 0);
        assertEq(p.tracker1UpdatedGrowth, 0);
        assertEq(p.tracker0Accumulated, 0);
        assertEq(p.tracker1Accumulated, 0);
        vamm.getRawPosition(positionId);
    }

    function test_TrackFixedTokens() public {
      int256 baseAmount = 99;
      int24 tickLower = 2;
      int24 tickUpper = 3;
      uint256 termEndTimestamp = block.timestamp + 100;
 
      UD60x18 currentLiquidityIndex = ud60x18(100e18);
      vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));

      (int256 trackedValue) = vamm.trackFixedTokens(baseAmount, tickLower, tickUpper, termEndTimestamp);
    //   assertEq(trackedValue, 0); // TODO: validate result
    }

    function test_NewPositionTracking() public {
        uint128 accountId = 1;
        int24 tickLower = 2;
        int24 tickUpper = 3;
        (uint256 positionId, DatedIrsVamm.LPPosition memory p) = openPosition(accountId,tickLower,tickUpper);

        // Position just opened so no filled balances
        (int256 baseBalancePool, int256 quoteBalancePool) = vamm.getAccountFilledBalances(accountId);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    
        // Position just opened so no unfilled balances
        UD60x18 currentLiquidityIndex = ud60x18(100e18);
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(currentLiquidityIndex));
        (int256 unfilledBaseLong, int256 unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);
        assertEq(unfilledBaseLong, 0);
        assertEq(unfilledBaseShort, 0);
    }
}