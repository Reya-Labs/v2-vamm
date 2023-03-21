pragma solidity >=0.8.13;

import "forge-std/Test.sol";
 import "forge-std/console.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";
import { UD60x18, convert } from "@prb/math/src/UD60x18.sol";
import { SD59x18, convert } from "@prb/math/src/SD59x18.sol";


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
    ExposedDatedIrsVamm exposedVamm;
    using DatedIrsVamm for DatedIrsVamm.Data;
    uint256 latestPositionId;
    uint256 testNumber;
    DatedIrsVamm.Data internal vamm;
    DatedIrsVamm.DatedIrsVAMMConfig internal config = DatedIrsVamm.DatedIrsVAMMConfig({
        priceImpactPhi: convert(uint256(0)),
        priceImpactBeta: convert(uint256(0)),
        spread: convert(uint256(0)),
        rateOracle: IRateOracle(address(0))
    });

    function setUp() public {
        exposedVamm = new ExposedDatedIrsVamm();
        vamm.initialize(uint160(FixedPoint96.Q96), block.timestamp+100, 0, 100, config);
        testNumber = 42;
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