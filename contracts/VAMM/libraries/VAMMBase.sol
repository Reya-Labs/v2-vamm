// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.8.13;

import "../../utils/AccessError.sol";
import "../interfaces/IVAMMBase.sol";
import "../libraries/Tick.sol";
import "../libraries/Tick.sol";
import "../libraries/TickBitmap.sol";
import "../../utils/SafeCastUni.sol";
import "../../utils/SqrtPriceMath.sol";
import "../../utils/CustomErrors.sol";
import "../libraries/SwapMath.sol";
import "prb-math/contracts/PRBMathUD60x18.sol";
import "prb-math/contracts/PRBMathSD59x18.sol";
import "../libraries/FixedAndVariableMath.sol";
import "../../utils/FixedPoint128.sol";
import "../interfaces/IVAMMBase.sol";

/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library VAMMBase {
    using SafeCastUni for uint256;
    using SafeCastUni for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);

    // events
    event Swap(
        address sender,
        address indexed recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int256 desiredNotional,
        uint160 sqrtPriceLimitX96,
        int256 tracker0Delta,
        int256 tracker1Delta
    );

    /// @dev emitted after a given vamm is successfully initialized
    event VAMMInitialization(uint160 sqrtPriceX96, int24 tick);

    /// @dev emitted after a successful minting of a given LP position
    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int256 amount
    );

    event VAMMPriceChange(int24 tick);

    struct TickData {
        mapping(int24 => Tick.Info) _ticks;
        mapping(int16 => uint256) _tickBitmap;
    }

    struct VAMMVars {
        /// @dev The current price of the pool as a sqrt(tracker1/tracker0) Q64.96 value
        uint160 sqrtPriceX96;
        /// @dev The current tick of the vamm, i.e. according to the last tick transition that was run.
        int24 tick;
    }

    struct SwapParams {
        /// @dev Address of the trader initiating the swap
        address recipient;
        /// @dev The amount of the swap, which implicitly configures the swap as exact input (positive), or exact output (negative)
        int256 amountSpecified;
        /// @dev The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
        uint160 sqrtPriceLimitX96;
        /// @dev lower tick of the position
        int24 tickLower;
        /// @dev upper tick of the position
        int24 tickUpper;
    }

    /// @dev the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        /// @dev the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        /// @dev current sqrt(price)
        uint160 sqrtPriceX96;
        /// @dev the tick associated with the current price
        int24 tick;
        /// @dev the global fixed token growth
        int256 tracker0GrowthGlobalX128;
        /// @dev the global variable token growth
        int256 tracker1GrowthGlobalX128;
        /// @dev the current liquidity in range
        uint128 accumulator;
        /// @dev tracker0Delta that will be applied to the fixed token balance of the position executing the swap (recipient)
        int256 tracker0DeltaCumulative;
        /// @dev tracker1Delta that will be applied to the variable token balance of the position executing the swap (recipient)
        int256 tracker1DeltaCumulative;
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
        int256 tracker0Delta; // for LP
        /// @dev ...
        int256 tracker1Delta; // for LP
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

    function baseBetweenTicks(
        int24 tickLower,
        int24 tickUpper,
        int256 accumulator
    ) internal pure returns(int256) {
        return accumulator * (tickUpper - tickLower);
    }

    function flipTicks(
        FlipTicksParams memory params,
        mapping(int24 => Tick.Info) storage _ticks,
        mapping(int16 => uint256) storage _tickBitmap,
        VAMMVars memory _vammVars,
        int256 _tracker0GrowthGlobalX128,
        int256 _tracker1GrowthGlobalX128,
        uint128 _maxLiquidityPerTick,
        int24 _tickSpacing
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
            params.accumulatorDelta,
            _tracker0GrowthGlobalX128,
            _tracker1GrowthGlobalX128,
            false,
            _maxLiquidityPerTick
        );

        /// @dev isUpper = true
        flippedUpper = _ticks.update(
            params.tickUpper,
            _vammVars.tick,
            params.accumulatorDelta,
            _tracker0GrowthGlobalX128,
            _tracker1GrowthGlobalX128,
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
        require(_unlocked, "LOK");
        _unlocked = false;
    }

    function unlock(bool _unlocked) internal pure {
        require(!_unlocked, "NLOK");
        _unlocked = true;
    }

    function checksBeforeSwap(
        SwapParams memory params,
        VAMMVars memory vammVarsStart,
        bool isFT
    ) internal pure {

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
    function checkCurrentTimestampTermEndTimestampDelta(uint256 termEndTimestampWad) internal view {
        if (Time.isCloseToMaturityOrBeyondMaturity(termEndTimestampWad)) {
            revert("closeToOrBeyondMaturity");
        }
    }
}
