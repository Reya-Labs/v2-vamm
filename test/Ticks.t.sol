pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/src/UD60x18.sol";
import { SD59x18 } from "@prb/math/src/SD59x18.sol";

// Constants
contract TicksTest is Test {

    using Tick for mapping(int24 => Tick.Info);
    mapping(int24 => Tick.Info) _ticks;

    function test_UpdateZeroToNonZero()
    public {
        assertEq(_ticks.update(0, 0, 1, 0, 0, false, 3), true);
    }

    function test_UpdateNonZeroToGreaterNonZero()
    public {
        _ticks.update(0, 0, 1, 0, 0, false, 3);
        assertEq(_ticks.update(0, 0, 1, 0, 0, false, 3), false);
    }

    function test_UpdateNonZeroToZero()
    public {
        _ticks.update(0, 0, 1, 0, 0, false, 3);
        assertEq(_ticks.update(0, 0, -1, 0, 0, false, 3), true);
    }
}