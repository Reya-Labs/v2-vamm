// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.8.13;

import "./Tick.sol";
import "./TickBitmap.sol";
import "./VammConfiguration.sol";


import "./FullMath.sol";
import "./FixedPoint96.sol";
import "./FixedPoint128.sol";

import "../CustomErrors.sol";
import "../Time.sol";

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
        uint128 marketId,
        uint32 maturityTimestamp,
        address sender,
        int256 desiredBaseAmount,
        uint160 sqrtPriceLimitX96,
        int256 quoteTokenDelta,
        int256 baseTokenDelta,
        uint256 blockTimestamp
    );

    /// @dev emitted after a successful mint or burn of liquidity on a given LP position
    event LiquidityChange(
        uint128 marketId,
        uint32 maturityTimestamp,
        address sender,
        uint128 indexed accountId,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int128 liquidityDelta,
        uint256 blockTimestamp
    );

    event VAMMPriceChange(uint128 indexed marketId, uint32 indexed maturityTimestamp, int24 tick, uint256 blockTimestamp);

    // STRUCTS

    /// @dev the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        /// @dev the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        /// @dev current sqrt(price)
        uint160 sqrtPriceX96;
        /// @dev the tick associated with the current price
        int24 tick;
        /// @dev the global quote token growth
        int256 trackerQuoteTokenGrowthGlobalX128;
        /// @dev the global variable token growth
        int256 trackerBaseTokenGrowthGlobalX128;
        /// @dev the current liquidity in range
        uint128 liquidity;
        /// @dev quoteTokenDelta that will be applied to the quote token balance of the position executing the swap
        int256 quoteTokenDeltaCumulative;
        /// @dev baseTokenDelta that will be applied to the variable token balance of the position executing the swap
        int256 baseTokenDeltaCumulative;
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
        int256 unbalancedQuoteTokenDelta;
        /// @dev ...
        int256 quoteTokenDelta; // for LP
        /// @dev ...
        int256 baseTokenDelta; // for LP
    }

    struct FlipTicksParams {
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    struct VammData {
        int256 _trackerQuoteTokenGrowthGlobalX128;
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

    function getPriceFromTick(int24 _tick) internal pure returns (UD60x18 price) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return UD60x18.wrap(FullMath.mulDiv(1e18, FixedPoint96.Q96, priceX96));
    }

    function calculateQuoteTokenDelta(
        int256 unbalancedQuoteTokenDelta,
        int256 baseTokenDelta,
        UD60x18 yearsUntilMaturity,
        UD60x18 currentOracleValue
    ) 
        internal
        pure
        returns (
            int256 balancedQuoteTokenDelta
        )
    {
        UD60x18 averagePrice = SD59x18.wrap(
            unbalancedQuoteTokenDelta
        ).div(SD59x18.wrap(baseTokenDelta)).div(
            convert_sd(-100)
        ).intoUD60x18();

        balancedQuoteTokenDelta = SD59x18.wrap(
            -baseTokenDelta
        ).mul(currentOracleValue.intoSD59x18()).mul(
            ONE.add(averagePrice.mul(yearsUntilMaturity)).intoSD59x18()
        ).unwrap();
    }

    function calculateGlobalTrackerValues(
        VAMMBase.SwapState memory state,
        int256 balancedQuoteTokenDelta,
        int256 baseTokenDelta
    ) 
        internal
        pure
        returns (
            int256 stateQuoteTokenGrowthGlobalX128,
            int256 stateBaseTokenGrowthGlobalX128
        )
    {
        stateQuoteTokenGrowthGlobalX128 = 
            state.trackerQuoteTokenGrowthGlobalX128 + 
                FullMath.mulDivSigned(balancedQuoteTokenDelta, FixedPoint128.Q128, state.liquidity);

        stateBaseTokenGrowthGlobalX128 = 
            state.trackerBaseTokenGrowthGlobalX128 + 
                FullMath.mulDivSigned(baseTokenDelta, FixedPoint128.Q128, state.liquidity);
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
        Tick.checkTicks(params.tickLower, params.tickUpper);

        /// @dev isUpper = false
        flippedLower = _ticks.update(
            params.tickLower,
            _vammVars.tick,
            params.liquidityDelta,
            data._trackerQuoteTokenGrowthGlobalX128,
            data._trackerBaseTokenGrowthGlobalX128,
            false,
            data._maxLiquidityPerTick
        );

        /// @dev isUpper = true
        flippedUpper = _ticks.update(
            params.tickUpper,
            _vammVars.tick,
            params.liquidityDelta,
            data._trackerQuoteTokenGrowthGlobalX128,
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
    function checkCurrentTimestampMaturityTimestampDelta(uint32 maturityTimestamp) internal view {
        if (Time.isCloseToMaturityOrBeyondMaturity(maturityTimestamp)) {
            revert("closeToOrBeyondMaturity");
        }
    }
}
