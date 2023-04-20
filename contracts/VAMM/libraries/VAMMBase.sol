// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.8.13;

import "../../utils/AccessError.sol";
import "../interfaces/IVAMMBase.sol";
import "../libraries/Tick.sol";
import "../libraries/Tick.sol";
import "../libraries/TickBitmap.sol";
import "./VammConfiguration.sol";
import "../../utils/SafeCastUni.sol";
import "../../utils/SqrtPriceMath.sol";
import "../../utils/CustomErrors.sol";
import "../libraries/SwapMath.sol";
import { UD60x18 } from "@prb/math/src/UD60x18.sol";
import { SD59x18, convert as convert_sd } from "@prb/math/src/SD59x18.sol";
import { ud60x18 } from "../../utils/PrbMathHelper.sol";
import "../libraries/FixedAndVariableMath.sol";
import "../../utils/FixedPoint128.sol";
import "../interfaces/IVAMMBase.sol";
import "forge-std/console2.sol"; // TODO: remove


/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library VAMMBase {
    using SafeCastUni for uint256;
    using SafeCastUni for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);

    SD59x18 constant PRICE_EXPONENT_BASE = SD59x18.wrap(10001e14); // 1.0001
    UD60x18 constant PRICE_EXPONENT_BASE_MINUS_ONE = UD60x18.wrap(1e14); // 0.0001

    struct TickData {
        mapping(int24 => Tick.Info) _ticks;
        mapping(int16 => uint256) _tickBitmap;
    }

    // ==================== EVENTS ======================
    /// @dev emitted after a successful swap transaction
    event Swap(
        address sender,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int256 desiredBaseAmount,
        uint160 sqrtPriceLimitX96,
        int256 trackerFixedTokenDelta,
        int256 trackerBaseTokenDelta
    );

    /// @dev emitted after a given vamm is successfully initialized
    event VAMMInitialization(uint160 sqrtPriceX96, int24 tick);

    /// @dev emitted after a successful minting of a given LP position
    event Mint(
        address sender,
        uint128 indexed accountId,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int128 requestedBaseAmount,
        int128 executedBaseAmount
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
        uint128 accumulator;
        /// @dev trackerFixedTokenDelta that will be applied to the fixed token balance of the position executing the swap (recipient)
        int256 trackerFixedTokenDeltaCumulative;
        /// @dev trackerBaseTokenDelta that will be applied to the variable token balance of the position executing the swap (recipient)
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
        int128 accumulatorDelta;
    }

    /// @dev Computes the agregate amount of base between two ticks, given a tick range and the amount of base per tick.
    /// The answer must be a valid `int128` (because total liquidity is limited to `int128`). Reverts on overflow.
    function baseBetweenTicks(
        int24 _tickLower,
        int24 _tickUpper,
        int128 _basePerTick
    ) internal pure returns(int128) {
        return _basePerTick * (_tickUpper - _tickLower);
    }

    /// @dev Computes the amount of base per tick, given a tick range and an aggregate base amount
    function basePerTick(
        int24 _tickLower,
        int24 _tickUpper,
        int128 _aggregateBaseAmount
    ) internal pure returns(int128) {
        return _aggregateBaseAmount / (_tickUpper - _tickLower);
    }

    function getPriceFromTick(int24 _tick) public pure returns(UD60x18 price) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return UD60x18.wrap(FullMath.mulDiv(priceX96, 1e18, FixedPoint96.Q96));
    }

    // @dev Returns the sum of `1.0001^x` for `x`=0,...,`tick`, using the the fact that this equals `1.0001^(n+1) / (1-1.0001)`
    function sumOfAllPricesUpTo(int24 tick) public pure returns(UD60x18 price) {
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
        return sumOfAllPricesUpTo(_tickUpper).sub(sumOfAllPricesUpTo(_tickLower - 1)).div(convert(uint256(int256(1 + _tickUpper - _tickLower))));
    }

    function flipTicks(
        FlipTicksParams memory params,
        mapping(int24 => Tick.Info) storage _ticks,
        mapping(int16 => uint256) storage _tickBitmap,
        VammConfiguration.State storage _vammVars,
        int256 _trackerVariableTokenGrowthGlobalX128,
        int256 _trackerBaseTokenGrowthGlobalX128,
        uint128 _maxLiquidityPerTick,
        int24 _tickSpacing
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
            params.accumulatorDelta,
            _trackerVariableTokenGrowthGlobalX128,
            _trackerBaseTokenGrowthGlobalX128,
            false,
            _maxLiquidityPerTick
        );

        /// @dev isUpper = true
        flippedUpper = _ticks.update(
            params.tickUpper,
            _vammVars.tick,
            params.accumulatorDelta,
            _trackerVariableTokenGrowthGlobalX128,
            _trackerBaseTokenGrowthGlobalX128,
            true,
            _maxLiquidityPerTick
        );

        if (flippedLower) {
            _tickBitmap.flipTick(params.tickLower, _tickSpacing);
        }

        if (flippedUpper) {
            _tickBitmap.flipTick(params.tickUpper, _tickSpacing);
        }
    }

    function whenNotPaused(bool paused) internal pure {
        require(!paused, "Paused");
    }

    function lock(bool _unlocked) internal pure {
        if (!_unlocked) {
            revert CustomErrors.CanOnlyTradeIfUnlocked();
        }
        _unlocked = false;
    }

    function unlock(bool _unlocked) internal pure {
        if (_unlocked) {
            revert CustomErrors.CanOnlyUnlockIfLocked();
        }
        _unlocked = true;
    }

    function checksBeforeSwap(
        IVAMMBase.SwapParams memory params,
        VammConfiguration.State storage vammVarsStart,
        bool isFT
    ) internal view {

        if (params.baseAmountSpecified == 0) {
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
