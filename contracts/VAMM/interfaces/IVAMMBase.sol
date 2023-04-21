// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.8.13;

import "../libraries/Tick.sol";
import "./IVAMM.sol";

interface IVAMMBase is IVAMM {

    // ===================== STRUCTS ===================

    /// @dev Internal, frequently-updated state of the VAMM, which is comp[ressed into one storage slot.
    struct VAMMVars {
        /// @dev The current price of the pool as a sqrt(trackerBaseToken/trackerVariableToken) Q64.96 value
        uint160 sqrtPriceX96;
        /// @dev The current tick of the vamm, i.e. according to the last tick transition that was run.
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // the current protocol fee as a percentage of the swap fee taken on withdrawal
        // represented as an integer denominator (1/x)%
        uint8 feeProtocol;
        // whether the pool is locked
        bool unlocked;
    }

    struct SwapParams {
        /// @dev Address of the trader initiating the swap
        address recipient;
        /// @dev The amount of the swap in base tokens, which implicitly configures the swap as exact input (positive), or exact output (negative)
        int256 baseAmountSpecified;
        /// @dev The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
        uint160 sqrtPriceLimitX96;
    }

    /// @dev "constructor" for proxy instances
    function initialize(int24 __tickSpacing)
        external;

    // immutables

    /// @notice The vamm tick spacing
    /// @dev Ticks can only be used at multiples of this value, minimum of 1 and always positive
    /// e.g.: a tickSpacing of 3 means ticks can be initialized every 3rd tick, i.e., ..., -6, -3, 0, 3, 6, ...
    /// This value is an int24 to avoid casting even though it is always positive.
    /// @return The tick spacing
    function tickSpacing() external view returns (int24);

    /// @notice The maximum amount of position liquidity that can use any tick in the range
    /// @dev This parameter should be enforced per tick (when setting) to prevent liquidity from overflowing a uint128 at any point, and
    /// also prevents out-of-range liquidity from being used to prevent adding in-range liquidity to the vamm
    /// @return The max amount of liquidity per tick
    function maxLiquidityPerTick() external view returns (uint128);

    // state variables

    /// @return The current VAMM Vars (see struct definition for semantics)
    function vammVars() external view returns (VAMMVars memory);

    /// @notice The fixed token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @dev This value can overflow the uint256
    function trackerFixedTokenGrowthGlobalX128() external view returns (int256);

    /// @notice The variable token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @dev This value can overflow the uint256
    function trackerBaseTokenGrowthGlobalX128() external view returns (int256);

    /// @notice The currently in range liquidity available to the vamm
    function accumulator() external view returns (uint128);

    /// @notice Sets the initial price for the vamm
    /// @dev Price is represented as a sqrt(amountVariableToken/amountFixedToken) Q64.96 value
    /// @param sqrtPriceX96 the initial sqrt price of the vamm as a Q64.96
    function initializeVAMM(uint160 sqrtPriceX96) external;

    /// @notice Adds liquidity for the given recipient/tickLower/tickUpper position
    /// @param recipient The address for which the liquidity will be created
    /// @param tickLower The lower tick of the position in which to add liquidity
    /// @param tickUpper The upper tick of the position in which to add liquidity
    /// @param amount The amount of liquidity to mint
    function mint(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external returns (int256 positionMarginRequirement);

    /// @notice Initiate an Interest Rate Swap
    /// @param params SwapParams necessary to initiate an Interest Rate Swap
    /// @return trackerFixedTokenDelta Fixed Token Delta
    /// @return trackerBaseTokenDelta Variable Token Delta
    /// @return cumulativeFeeIncurred Cumulative Fee Incurred
    function swap(SwapParams memory params)
        external
        returns (
            int256 trackerFixedTokenDelta,
            int256 trackerBaseTokenDelta,
            uint256 cumulativeFeeIncurred
        );

    
    /// @notice Look up information about a specific tick in the amm
    /// @param tick The tick to look up
    /// @return liquidityGross: the total amount of position liquidity that uses the vamm either as tick lower or tick upper,
    /// liquidityNet: how much liquidity changes when the vamm price crosses the tick
    function ticks(int24 tick) external view returns (Tick.Info memory);

    /// @notice Returns 256 packed tick initialized boolean values. See TickBitmap for more information
    function tickBitmap(int16 wordPosition) external view returns (uint256);

    /// @notice Computes the current fixed and variable token growth inside a given tick range given the current tick in the vamm
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @return trackerVariableTokenGrowthInsideX128 Fixed Token Growth inside the given tick range
    /// @return trackerBaseTokenGrowthInsideX128 Variable Token Growth inside the given tick rangee
    function computeGrowthInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (
            int256 trackerVariableTokenGrowthInsideX128,
            int256 trackerBaseTokenGrowthInsideX128
        );
}
