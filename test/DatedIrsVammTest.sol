pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./VoltzTest.sol";
import "../utils/SafeCastUni.sol";
import "../contracts/VAMM/storage/LPPosition.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import "../contracts/VAMM/storage/LPPosition.sol";
import "../contracts/VAMM/libraries/Tick.sol";

import { mulUDxInt } from "../utils/PrbMathHelper.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/src/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/src/SD59x18.sol";

/// @dev Contains assertions and other functions used by multiple tests
contract DatedIrsVammTest is VoltzTest {
    // Contracts under test
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastUni for uint256;
    using SafeCastUni for int256;
    uint256 internal vammId;
    address constant mockRateOracle = 0xAa73aA73Aa73Aa73AA73Aa73aA73AA73aa73aa73;

    // Initial VAMM state
    uint160 initSqrtPriceX96 = uint160(2 * FixedPoint96.Q96 / 10); // 0.2 => price ~= 0.04 = 4%
    uint128 initMarketId = 1;
    int24 initTickSpacing = 1; // TODO: test with different tick spacing; need to adapt boundTicks()
    uint256 initMaturityTimestamp = block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR);
    VammConfiguration.Mutable internal mutableConfig = VammConfiguration.Mutable({
        priceImpactPhi: ud60x18(1e17), // 0.1
        priceImpactBeta: ud60x18(125e15), // 0.125
        spread: ud60x18(3e15), // 0.3%
        rateOracle: IRateOracle(mockRateOracle)
    });

    VammConfiguration.Immutable internal immutableConfig = VammConfiguration.Immutable({
        maturityTimestamp: initMaturityTimestamp,
        _maxLiquidityPerTick: type(uint128).max,
        _tickSpacing: initTickSpacing
    });

    function tickDistanceFromCurrentToTick(int24 _tick) public view returns (uint256 absoluteDistance) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int24 currentTick = vamm.vars.tick;
        return tickDistance(currentTick, _tick);
    }

    function boundNewPositionLiquidityAmount(
        int128 unboundBaseToken,
        int24 _tickLower,
        int24 _tickUpper)
    internal view returns (int128 boundBaseTokens)
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        // Ticks must be in range and cannot be equal
        uint256 tickRange = tickDistance(_tickLower, _tickUpper);
        uint128 maxLiquidityPerTick = vamm.immutableConfig._maxLiquidityPerTick;
        // console2.log("tickRange", tickRange); // TODO_delete_log
        // console2.log("maxLiquidityPerTick", maxLiquidityPerTick, maxLiquidityPerTick * tickRange); // TODO_delete_log
        int256 max = min(int256(type(int128).max), int256(uint256(maxLiquidityPerTick)) * int256(tickRange));

        return int128(bound(unboundBaseToken, 0, max)); // New positions cannot withdraw liquidity so >= 0
    }

    function logTickInfo(string memory label, int24 _tick) view internal {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        console2.log(label);
        console2.log("- tickNumber", int256(_tick));
        Tick.Info storage t = vamm.vars._ticks[_tick];
        console2.log("- liquidityGross", uint256(t.liquidityGross));
        console2.log("- liquidityNet", int256(t.liquidityNet));
        console2.log("- trackerVariableTokenGrowthOutsideX128", t.trackerVariableTokenGrowthOutsideX128);
        console2.log("- trackerBaseTokenGrowthOutsideX128", t.trackerBaseTokenGrowthOutsideX128);
        console2.log("- initialized", t.initialized);
    }
}