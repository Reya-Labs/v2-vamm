// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.8.13;

import "./Tick.sol";
import "./TickBitmap.sol";
import "./VammConfiguration.sol";
import "forge-std/console2.sol"; // TODO: remove


import "./FullMath.sol";
import "./FixedPoint96.sol";
import "./FixedPoint128.sol";

import "../CustomErrors.sol";
import "../Time.sol";

import "forge-std/console2.sol";

import { UD60x18, unwrap, convert as convert_ud } from "@prb/math/UD60x18.sol";
import { SD59x18, convert as convert_sd } from "@prb/math/SD59x18.sol";

import { ud60x18, mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library VAMMBase {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);

    UD60x18 constant ONE = UD60x18.wrap(1e18);
    SD59x18 constant PRICE_EXPONENT_BASE = SD59x18.wrap(10001e14); // 1.0001
    UD60x18 constant PRICE_EXPONENT_BASE_MINUS_ONE = UD60x18.wrap(1e14); // 0.0001
    uint256 internal constant Q96 = 2**96;

    struct TickData {
        mapping(int24 => Tick.Info) _ticks;
        mapping(int16 => uint256) _tickBitmap;
    }

    struct SwapParams {
        /// @dev The amount of the swap in base tokens, which implicitly configures the swap as exact input (positive), or exact output (negative)
        int256 amountSpecified;
        /// @dev The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
        uint160 sqrtPriceLimitX96;
    }

    // ==================== EVENTS ======================
    /// @dev emitted after a successful swap transaction
    event Swap(
        address sender,
        int256 desiredBaseAmount,
        uint160 sqrtPriceLimitX96,
        int256 trackerFixedTokenDelta,
        int256 trackerBaseTokenDelta
    );

    /// @dev emitted after a given vamm is successfully initialized
    event VAMMInitialization(uint160 sqrtPriceX96, int24 tick);

    /// @dev emitted after a successful mint or burn of liquidity on a given LP position
    event LiquidityChange(
        address sender,
        uint128 indexed accountId,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int128 liquidityDelta
    );

    event VAMMPriceChange(int24 tick);

    // STRUCTS

    /// @dev the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        /// @dev the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        /// @dev current sqrt(price)
        uint160 sqrtPriceX96;
        /// @dev the tick associated with the current price
        int24 tick;
        /// @dev the global fixed token growth
        int256 trackerFixedTokenGrowthGlobalX128;
        /// @dev the global variable token growth
        int256 trackerBaseTokenGrowthGlobalX128;
        /// @dev the current liquidity in range
        uint128 liquidity;
        /// @dev trackerFixedTokenDelta that will be applied to the fixed token balance of the position executing the swap
        int256 trackerFixedTokenDeltaCumulative;
        /// @dev trackerBaseTokenDelta that will be applied to the variable token balance of the position executing the swap
        int256 trackerBaseTokenDeltaCumulative;
    }

    struct StepComputations {
        /// @dev the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        /// @dev the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        /// @dev whether tickNext is initialized or not
        bool initialized;
        /// @dev sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        /// @dev how much is being swapped in in this step
        uint256 amountIn;
        /// @dev how much is being swapped out
        uint256 amountOut;
        /// @dev ...
        int256 trackerFixedTokenDelta; // for LP
        /// @dev ...
        int256 trackerBaseTokenDelta; // for LP
        /// @dev the amount swapped out/in of the output/input asset during swap step
        int256 baseInStep;
    }

    struct FlipTicksParams {
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    struct VammData {
        int256 _trackerFixedTokenGrowthGlobalX128;
        int256 _trackerBaseTokenGrowthGlobalX128;
        uint128 _maxLiquidityPerTick;
        int24 _tickSpacing;
    }

    /// @dev Computes the agregate amount of base between two ticks, given a tick range and the amount of liquidity per tick.
    /// The answer must be a valid `int256`. Reverts on overflow.
    function baseBetweenTicks(
        int24 _tickLower,
        int24 _tickUpper,
        int128 _liquidityPerTick
    ) internal view returns(int256) {
        // get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(_tickLower);

        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(_tickUpper);

        return baseAmountFromLiquidity(_liquidityPerTick, sqrtRatioAX96, sqrtRatioBX96);
    }

    /// @notice Computes the amount of notional coresponding to an amount of liquidity and price range
    /// @dev Calculates amount1 * (sqrt(upper) - sqrt(lower)).
    /// @param liquidity Liquidity per tick
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @return baseAmount The base amount of returned from liquidity
    function baseAmountFromLiquidity(int128 liquidity, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) internal view returns (int256 baseAmount){
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 absBase = FullMath
                .mulDiv(uint128(liquidity > 0 ? liquidity : -liquidity), sqrtRatioBX96 - sqrtRatioAX96, Q96);

        baseAmount = liquidity > 0 ? absBase.toInt() : -(absBase.toInt());
    }

    function getPriceFromTick(int24 _tick) internal pure returns(UD60x18 price) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return UD60x18.wrap(FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96));
    }

    /// @dev Private but labelled internal for testability.
    ///
    /// @dev Calculate `fixedTokens` for some tick range that has uniform liquidity within a trade. The calculation relies
    /// on the trade being uniformly distributed across the specified tick range in order to calculate the average price (the fixedAPY), so this
    /// assumption must hold or the math will break. As such, the function can only really be useed to calculate `fixedTokens` for a subset of a trade,
    ///
    /// Thinking about cashflows from first principles, the cashflow of an IRS at time `x` (`x < maturityTimestamp`) is:
    ///  (1)  `cashflow[x] = notional * (variableAPYBetween[tradeDate, x] - fixedAPY) * timeInYearsBetween[tradeDate, x]`   
    /// We use liquidity indices to track variable rates, such that
    ///  (2)  `variableAPYBetween[tradeDate, x] * timeInYearsBetween[tradeDate, x] = (liquidityIndex[x] / liquidityIndex[tradeDate]) - 1     
    /// We can therefore rearrange (1) as:
    ///       `cashflow[x] = notional * ((variableAPYBetween[tradeDate, x]*timeInYearsBetween[tradeDate, x]) - (fixedAPY*timeInYearsBetween[tradeDate, x]))`   
    ///       `cashflow[x] = notional * ((liquidityIndex[x] / liquidityIndex[tradeDate]) - 1 - (fixedAPY*timeInYearsBetween[tradeDate, x]))`   
    ///   (3) `cashflow[x] = notional*(liquidityIndex[x] / liquidityIndex[tradeDate]) - notional*(1 + fixedAPY*timeInYearsBetween[tradeDate, x])`
    /// Now if we define:
    ///   `baseTokens:= notional / liquidityIndex[tradeDate]`
    /// then we can further rearrange (3) as:
    ///       `cashflow[x] = baseTokens*liquidityIndex[x] - baseTokens*liquidityIndex[tradeDate]*(1 + fixedAPY*timeInYearsBetween[tradeDate, x])`
    /// And now if we define:
    ///   `fixedTokens:= -baseTokens*liquidityIndex[tradeDate]*(1 + fixedAPY*timeInYearsBetween[tradeDate, maturityTimestamp])
    /// Then we will have simply:
    ///   (4) `cashflow[maturity] = baseTokens*liquidityIndex[maturity] + fixedTokens`
    /// 
    /// In Voltz, `baseTokens` is calculated off-chain based on the desired notional, and is one of the inputs that the smart contracts see when a trade is made.
    ///
    /// The following function helps with the calculation of `fixedTokens`.
    ///
    /// Pluggin in a fixed Rate or 0 and we see that
    ///   `cashflow[x] = baseTokens*liquidityIndex[x] - baseTokens*liquidityIndex[tradeDate]*(1 + fixedAPY*timeInYearsBetween[tradeDate, x])`
    /// now simplifies to:
    ///   `cashflow[x] = baseTokens*liquidityIndex[x] - baseTokens*liquidityIndex[tradeDate]`
    /// which is what we want.
    function _fixedTokensInHomogeneousTickWindow( // TODO: previously called trackFixedTokens; update python code to match new name 
      int256 baseAmount,
      int24 tickLower,
      int24 tickUpper,
      UD60x18 yearsUntilMaturity,
      UD60x18 currentOracleValue
    )
        internal
        view
        returns (
            int256 trackedValue
        )
    {
        UD60x18 averagePrice = VAMMBase.averagePriceBetweenTicks(tickLower, tickUpper);
        UD60x18 timeComponent = ONE.add(averagePrice.mul(yearsUntilMaturity)); // (1 + fixedRate * timeInYearsTillMaturity)
        trackedValue = mulUDxInt(
            currentOracleValue.mul(timeComponent),
            -baseAmount
        );
    }

    /// @dev Private but labelled internal for testability.
    function _calculateUpdatedGlobalTrackerValues(
        VAMMBase.SwapState memory state,
        VAMMBase.StepComputations memory step,
        UD60x18 yearsUntilMaturity,
        UD60x18 currentOracleValue
    )
        internal
        view
        returns (
            int256 stateFixedTokenGrowthGlobalX128,
            int256 stateBaseTokenGrowthGlobalX128,
            int256 fixedTokenDelta
        )
    {
        // console2.log("accumulating", state.liquidity); // TODO_delete_log
        // Get the numder of fixed tokens for the current section of our swap's tick range
        // This calculation assumes that the trade is uniformly distributed within the given tick range, which is only
        // true because there are no changes in liquidity between `state.tick` and `step.tickNext`.
        fixedTokenDelta = VAMMBase._fixedTokensInHomogeneousTickWindow(
            step.trackerBaseTokenDelta,
            state.tick < step.tickNext ? state.tick : step.tickNext,
            state.tick > step.tickNext ? state.tick : step.tickNext,
            yearsUntilMaturity,
            currentOracleValue
        );

        // update global trackers
        // note this calculation is not precise with very small trackerBaseTokenDelta values 
        stateBaseTokenGrowthGlobalX128 = state.trackerBaseTokenGrowthGlobalX128 + FullMath.mulDivSigned(step.trackerBaseTokenDelta, FixedPoint128.Q128, state.liquidity);
        stateFixedTokenGrowthGlobalX128 = state.trackerFixedTokenGrowthGlobalX128 + FullMath.mulDivSigned(fixedTokenDelta, FixedPoint128.Q128, state.liquidity);
        // console2.log("COMP state.liquidity", state.liquidity);
        // console2.log("COMP state.fixedTokenGrowthGlobalX128", state.trackerFixedTokenGrowthGlobalX128);
        // console2.log("COMP stateFixedTokenGrowthGlobalX128", stateFixedTokenGrowthGlobalX128);
    }

    /// @dev Private but labelled internal for testability.
    /// 
    /// @dev The sum of `1.0001^x` for `x`=0,...,`tick`, equals `(1.0001^(tick+1) - 1) / (1.0001-1)`. This can be positive or nagative.
    /// The `- 1 / (1.0001-1)` part of that forumla equals `-10000`. If we skip this subtraction then:
    /// (A) there is less math to do
    /// (B) we can guarantee that the result is positive (because `1.0001^(n+1)` is positive) and return an unsigned value
    ///
    /// For those reasons, we return not the sum of `1.0001^x` for `x`=0,...,`n`, but that sum plus 10,000.
    function _sumOfAllPricesUpToPlus10k(int24 tick) internal pure returns(UD60x18 price) {
        // Tick might be negative and UD60x18 does not support `.pow(x)` for x < 0, so we must use SD59x18
        SD59x18 numeratorSigned = PRICE_EXPONENT_BASE.pow(convert_sd(int256(tick + 1)));

        // We know that 1.0001^x is positive even for negative x, so we can safely cast to UD60x18 now
        UD60x18 numerator = ud60x18(numeratorSigned);
        return numerator.div(PRICE_EXPONENT_BASE_MINUS_ONE);
    }

    /// @dev Computes the average price of a trade, assuming uniform distribution of the trade across the specified tick range.
    /// This assumption makes it unsuitable for determining the average price of a whole trade that crosses tick boundaries where liquidity changes.
    function averagePriceBetweenTicks(
        int24 _tickLower,
        int24 _tickUpper
    ) internal pure returns(UD60x18) {
        // As both of the below results are 10k too large, the difference between them will be correct
        // The division is inversed because price = 1.0001^-tick
        return (convert_ud(uint256(
                int256(1 + _tickUpper - _tickLower)
            )))
            .div(_sumOfAllPricesUpToPlus10k(_tickUpper)
                .sub(_sumOfAllPricesUpToPlus10k(_tickLower - 1))
            );
    }

    function flipTicks(
        FlipTicksParams memory params,
        mapping(int24 => Tick.Info) storage _ticks,
        mapping(int16 => uint256) storage _tickBitmap,
        VammConfiguration.State storage _vammVars,
        VammData memory data
    )
        internal
        returns (
            bool flippedLower,
            bool flippedUpper
        )
    {
        // console2.log("flipTicks: ticks = (%s, %s)", uint256(int256(params.tickLower)), uint256(int256(params.tickUpper))); // TODO_delete_log
        Tick.checkTicks(params.tickLower, params.tickUpper);

        /// @dev isUpper = false
        flippedLower = _ticks.update(
            params.tickLower,
            _vammVars.tick,
            params.liquidityDelta,
            data._trackerFixedTokenGrowthGlobalX128,
            data._trackerBaseTokenGrowthGlobalX128,
            false,
            data._maxLiquidityPerTick
        );

        /// @dev isUpper = true
        flippedUpper = _ticks.update(
            params.tickUpper,
            _vammVars.tick,
            params.liquidityDelta,
            data._trackerFixedTokenGrowthGlobalX128,
            data._trackerBaseTokenGrowthGlobalX128,
            true,
            data._maxLiquidityPerTick
        );

        if (flippedLower) {
            _tickBitmap.flipTick(params.tickLower, data._tickSpacing);
        }

        if (flippedUpper) {
            _tickBitmap.flipTick(params.tickUpper, data._tickSpacing);
        }
    }

    function checksBeforeSwap(
        VAMMBase.SwapParams memory params,
        VammConfiguration.State storage vammVarsStart,
        bool isFT
    ) internal view {

        if (params.amountSpecified == 0) {
            revert CustomErrors.IRSNotionalAmountSpecifiedMustBeNonZero();
        }

        /// @dev if a trader is an FT, they consume fixed in return for variable
        /// @dev Movement from right to left along the VAMM, hence the sqrtPriceLimitX96 needs to be higher than the current sqrtPriceX96, but lower than the MAX_SQRT_RATIO
        /// @dev if a trader is a VT, they consume variable in return for fixed
        /// @dev Movement from left to right along the VAMM, hence the sqrtPriceLimitX96 needs to be lower than the current sqrtPriceX96, but higher than the MIN_SQRT_RATIO

        require(
            isFT
                ? params.sqrtPriceLimitX96 > vammVarsStart.sqrtPriceX96 &&
                    params.sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO
                : params.sqrtPriceLimitX96 < vammVarsStart.sqrtPriceX96 &&
                    params.sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO,
            "SPL"
        );
    }

    /// @dev Modifier that ensures new LP positions cannot be minted after one day before the maturity of the vamm
    /// @dev also ensures new swaps cannot be conducted after one day before maturity of the vamm
    function checkCurrentTimestampMaturityTimestampDelta(uint256 maturityTimestamp) internal view {
        if (Time.isCloseToMaturityOrBeyondMaturity(maturityTimestamp)) {
            revert("closeToOrBeyondMaturity");
        }
    }
}
