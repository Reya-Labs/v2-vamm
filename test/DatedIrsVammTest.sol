pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./VoltzTest.sol";
import "../src/storage/LPPosition.sol";
import "../src/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import "../src/storage/LPPosition.sol";
import "../utils/vamm-math/Tick.sol";

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/SD59x18.sol";

/// @dev Contains assertions and other functions used by multiple tests
contract DatedIrsVammTest is VoltzTest {
    // Contracts under test
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    uint256 internal vammId;
    address constant mockRateOracle = 0xAa73aA73Aa73Aa73AA73Aa73aA73AA73aa73aa73;

    // Initial VAMM state
    // Picking a price that lies on a tick boundry simplifies the math to make some tests and checks easier
    uint160 initSqrtPriceX96 = TickMath.getSqrtRatioAtTick(-32191); // price = ~0.04 = ~4%
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

    /// @notice Computes the amount of liquidity per tick to use for a given base amount and price range
    /// @dev Calculates `baseAmount / (sqrtRatio(tickUpper) - sqrtRatio(tickLower))`.
    /// @param tickLower The first tick boundary
    /// @param tickUpper The second tick boundary
    /// @param baseAmount The amount of base token being sent in
    /// @return liquidity The amount of liquidity per tick
    function getLiquidityForBase(
        int24 tickLower,
        int24 tickUpper,
        int256 baseAmount
    ) public view returns (int128 liquidity) {

        // get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 absLiquidity = FullMath
                .mulDiv(uint256(baseAmount > 0 ? baseAmount : -baseAmount), VAMMBase.Q96, sqrtRatioBX96 - sqrtRatioAX96);

        return baseAmount > 0 ? absLiquidity.toInt().to128() : -(absLiquidity.toInt().to128());
    }

    function tickDistanceFromCurrentToTick(int24 _tick) public view returns (uint256 absoluteDistance) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        int24 currentTick = vamm.vars.tick;
        return tickDistance(currentTick, _tick);
    }

    function boundNewPositionLiquidityAmount(
        int24 tickLower,
        int24 tickUpper,
        int128 unboundLiquidityDelta)
    internal view returns (int128 liquidityDelta)
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        // Ticks must be in range and cannot be equal
        // uint256 tickRange = tickDistance(_tickLower, _tickUpper);
        uint128 maxLiquidityPerTick = vamm.immutableConfig._maxLiquidityPerTick;
        //int256 max = min(int256(type(int128).max), int256(uint256(maxLiquidityPerTick)*tickRange));
        int256 max = min(int256(type(int128).max - 1), int256(uint256(maxLiquidityPerTick))); // TODO: why is type(int128).max not safe?

        // Amounts of liquidty smaller than required for base amount of 100k might produce acceptable rounding errors that nonetheless make tests fiddly
        int256 min = getLiquidityForBase(tickLower, tickUpper, 1000_000); 

        return int128(bound(unboundLiquidityDelta, min, max)); // New positions cannot withdraw liquidity so >= 0
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