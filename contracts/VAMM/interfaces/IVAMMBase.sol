// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.8.13;

import "../libraries/Tick.sol";
import "./IVAMM.sol";

interface IVAMMBase is IVAMM {
    function setPausability(bool state) external;

    // events
    event Swap(
        address sender,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int256 desiredNotional,
        uint160 sqrtPriceLimitX96,
        uint256 cumulativeFeeIncurred,
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
        uint128 amount
    );

    event VAMMPriceChange(int24 tick);

    // structs

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
        /// @dev the amount swapped out/in of the output/input asset during swap step
        int256 baseInStep;
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
    }

    struct FlipTicksParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 deltaAccumulator;
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
    function tracker0GrowthGlobalX128() external view returns (int256);

    /// @notice The variable token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @dev This value can overflow the uint256
    function tracker1GrowthGlobalX128() external view returns (int256);

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
    /// @return tracker0Delta Fixed Token Delta
    /// @return tracker1Delta Variable Token Delta
    /// @return cumulativeFeeIncurred Cumulative Fee Incurred
    function swap(SwapParams memory params)
        external
        returns (
            int256 tracker0Delta,
            int256 tracker1Delta,
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
    /// @return tracker0GrowthInsideX128 Fixed Token Growth inside the given tick range
    /// @return tracker1GrowthInsideX128 Variable Token Growth inside the given tick rangee
    function computeGrowthInside(int24 tickLower, int24 tickUpper)
        external
        view
        returns (
            int256 tracker0GrowthInsideX128,
            int256 tracker1GrowthInsideX128
        );

    
    /// @notice refreshes the Rate Oracle attached to the Margin Engine
    function refreshGTWAPOracle(address _gtwapOracle) external;

    /// @notice The rateOracle contract which lets the protocol access historical apys in the yield bearing pools it is built on top of
    /// @return The underlying ERC20 token (e.g. USDC)
    function GTWAPOracle() external view returns (address);
}
