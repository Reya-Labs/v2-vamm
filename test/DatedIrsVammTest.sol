pragma solidity >=0.8.13;

import "forge-std/Test.sol";
 import "forge-std/console.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";
import { UD60x18, convert } from "@prb/math/src/UD60x18.sol";
// import { PRBMathAssertions } from "@prb/math/src/test/Assertions.sol";
import { SD59x18 } from "@prb/math/src/SD59x18.sol";


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

contract VammTest is Test {

    function assertEq(UD60x18 a, UD60x18 b) internal {
        assertEq(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }

    function assertEq(UD60x18 a, UD60x18 b, string memory err) internal {
        assertEq(UD60x18.unwrap(a), UD60x18.unwrap(b), err);
    }

    // Contracts under test
    using DatedIrsVamm for DatedIrsVamm.Data;
    DatedIrsVamm.Data internal vamm;
    ExposedDatedIrsVamm exposedVamm;

    // Test state
    uint256 latestPositionId;

    // Initial VAMM state
    uint160 initSqrtPriceX96 = uint160(2 * FixedPoint96.Q96);
    uint128 initMarketId = 1;
    int24 initTickSpacing = 1000;
    DatedIrsVamm.DatedIrsVAMMConfig internal config = DatedIrsVamm.DatedIrsVAMMConfig({
        priceImpactPhi: convert(uint256(0)),
        priceImpactBeta: convert(uint256(0)),
        spread: convert(uint256(0)),
        rateOracle: IRateOracle(address(0))
    });

    function setUp() public {
        exposedVamm = new ExposedDatedIrsVamm();
        vamm.initialize(initSqrtPriceX96, block.timestamp + 100, initMarketId, initTickSpacing, config);
    }

    function test_InitState() public {
        assertEq(vamm._vammVars.sqrtPriceX96, initSqrtPriceX96); 
        assertEq(vamm._vammVars.tick, TickMath.getTickAtSqrtRatio(initSqrtPriceX96)); 
    }

    function test_InitOracle() public {
        int24 tick = vamm._vammVars.tick;
        assertEq(vamm.observe(0), tick); 
        UD60x18 geometricMeanPrice = vamm.twap(0, 0 , false); // no lookback, no adjustments
        assertEq(geometricMeanPrice, DatedIrsVamm.getPriceFromTick(tick)); 
    }

    function testFuzz_GetAverageBase(
        int24 tickLower,
        int24 tickUpper,
        int128 baseAmount)
    public {
        vm.assume(tickLower < tickUpper); // Ticks cannot be equal
        vm.assume(tickLower >= TickMath.MIN_TICK);
        vm.assume(tickUpper <= TickMath.MAX_TICK);
        assertEq(exposedVamm.getAverageBase(tickLower, tickUpper, baseAmount), baseAmount / (tickUpper - tickLower));
    }

    function testFail_GetUnopenedPosition() public {
        vamm.getRawPosition(1);
    }

    function test_OpenPosition() public {
        uint128 accountId = 1;
        int24 tickLower = 2;
        int24 tickUpper = 3;
        latestPositionId = vamm.openPosition(accountId,tickLower,tickUpper);
        assertEq(latestPositionId, DatedIrsVamm.getPositionId(accountId,tickLower,tickUpper));
        assertEq(vamm.positions[latestPositionId].accountId, accountId);
        assertEq(vamm.positions[latestPositionId].tickLower, tickLower);
        assertEq(vamm.positions[latestPositionId].tickUpper, tickUpper);
        vamm.getRawPosition(latestPositionId);
    }
}