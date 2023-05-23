pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../utils/vamm-math/TickMath.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/SD59x18.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";


/// @dev Contains assertions and other functions used by multiple tests
contract VoltzTest is Test {
    using SafeCastU256 for uint256;

    /// @dev The minimum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**-128
    int24 internal constant MIN_TICK = -69100;
    /// @dev The maximum tick that may be passed to #getSqrtRatioAtTick computed from log base 1.0001 of 2**128
    int24 internal constant MAX_TICK = -MIN_TICK;

    // Helpers
    function abs(int256 x) pure internal returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }
    function min(int256 a, int256 b) pure internal returns (int256) {
        return a > b ? b : a;
    }
    function min(int24 a, int24 b) pure internal returns (int24) {
        return a > b ? b : a;
    }
    // function max(int256 a, int256 b) pure internal returns (int256) {
    //     return a < b ? b : a;
    // }
    function logTicks(int24 a, int24 b, string memory _message) internal view {
        // string memory message = bytes(_message).length > 0 ? _message : "Ticks: ";
        console2.log(_message, bytes(_message).length > 0 ? " ticks: " : "Ticks:"); // TODO_delete_log
        console2.logInt(a);
        console2.logInt(b);
    }
    function boundTicks(
        int24 _tickLower,
        int24 _tickUpper)
    internal view returns (int24 tickLower, int24 tickUpper)
    {
        // Ticks must be in range and cannot be equal
        tickLower = int24(bound(_tickLower,  TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        tickUpper = int24(bound(_tickUpper,  TickMath.MIN_TICK + 1, TickMath.MAX_TICK));
        vm.assume(tickLower < tickUpper);
    }
    function tickDistance(int24 _tickA, int24 _tickB) public pure returns (uint256 absoluteDistance) {
        return abs(_tickA - _tickB);
    }
    function sqrtPriceDistanceX96(int24 _tickA, int24 _tickB) public pure returns (uint256 absoluteSqrtPriceDistanceX96) {
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(_tickA);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(_tickB);
        return abs(uint256(sqrtRatioAX96).toInt() - uint256(sqrtRatioBX96).toInt());
    }

    using SafeCastI256 for uint256;

    // Assertions
    function assertEq(UD60x18 a, UD60x18 b) internal {
        assertEq(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertEq(SD59x18 a, SD59x18 b) internal {
        assertEq(SD59x18.unwrap(a), SD59x18.unwrap(b));
    }
    function assertGt(UD60x18 a, UD60x18 b) internal {
        assertGt(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertLt(UD60x18 a, UD60x18 b) internal {
        assertLt(UD60x18.unwrap(a), UD60x18.unwrap(b));
    }
    function assertAlmostEqual(SD59x18 a, SD59x18 b, SD59x18 deltaAsFractionOfA) internal {
        if (SD59x18.unwrap(a) == SD59x18.unwrap(b)) {
            // Equal (needed for case where a = b = 0)
            return;
        }
        SD59x18 upperBound = SD59x18.unwrap(a) >= 0 ? a.add(deltaAsFractionOfA.mul(a)) : a.sub(deltaAsFractionOfA.mul(a));
        SD59x18 lowerBound = SD59x18.unwrap(a) >= 0 ? a.sub(deltaAsFractionOfA.mul(a)) : a.add(deltaAsFractionOfA.mul(a));
        if (b.gt(upperBound) || b.lt(lowerBound)) {
            // console2.log("Expected the following two values to be almost equal:"); // TODO_delete_log
            console2.logInt(SD59x18.unwrap(a));
            console2.logInt(SD59x18.unwrap(b));
        }
        assertGe(SD59x18.unwrap(b), SD59x18.unwrap(lowerBound) );
        assertLe(SD59x18.unwrap(b), SD59x18.unwrap(upperBound) );
    }
    function assertAlmostEqual(UD60x18 a, UD60x18 b, UD60x18 deltaAsFractionOfA) internal {
        if (UD60x18.unwrap(a) == UD60x18.unwrap(b)) {
            // Equal (needed for case where a = b = 0)
            return;
        }

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
    function assertAlmostExactlyEqual(UD60x18 a, UD60x18 b) internal {
        UD60x18 deltaAsFractionOfA = ud60x18(1e12); // 0.0001%
        assertAlmostEqual(a, b, deltaAsFractionOfA);
    }
    function assertAlmostEqual(SD59x18 a, SD59x18 b) internal {
        SD59x18 deltaAsFractionOfA = sd59x18(1e14); // 0.01%
        assertAlmostEqual(a, b, deltaAsFractionOfA);
    }
    function assertAlmostExactlyEqual(SD59x18 a, SD59x18 b) internal {
        SD59x18 deltaAsFractionOfA = sd59x18(1e12); // 0.0001%
        assertAlmostEqual(a, b, deltaAsFractionOfA);
    }
    function assertAlmostEqual(int256 a, int256 b) internal {
        assertAlmostEqual(SD59x18.wrap(a), SD59x18.wrap(b));
    }
    function assertAlmostEqual(int256 a, int256 b, uint256 deltaAsFractionOfA) internal {
        assertAlmostEqual(SD59x18.wrap(a), SD59x18.wrap(b), SD59x18.wrap(deltaAsFractionOfA.toInt()));
    }
    function assertOffByNoMoreThan2OrAlmostEqual(int256 a, int256 b) internal {
        if (abs(a-b) > 2) {
            assertAlmostEqual(SD59x18.wrap(a), SD59x18.wrap(b));
        }
    }
    function assertEq(UD60x18 a, UD60x18 b, string memory err) internal {
        assertEq(UD60x18.unwrap(a), UD60x18.unwrap(b), err);
    }
}