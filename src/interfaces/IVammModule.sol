// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/vamm-math/VammConfiguration.sol";

interface IVammModule {
  /// @dev Emitted when vamm configurations are updated
  event VammConfigUpdated(
      uint128 marketId,
      VammConfiguration.Mutable config,
      uint256 blockTimestamp
  );

  /// @dev Emitted when a new vamm is created and initialized
  event VammCreated(
      uint128 marketId,
      int24 tick,
      VammConfiguration.Immutable config,
      VammConfiguration.Mutable mutableConfig,
      uint256 blockTimestamp
  );

  /**
    * @notice registers a new vamm with the specified configurationsa and initializes the price
    */
  function createVamm(
    uint128 _marketId, 
    uint160 _sqrtPriceX96, 
    uint32[] memory times, 
    int24[] memory observedTicks, 
    VammConfiguration.Immutable calldata _config, 
    VammConfiguration.Mutable calldata _mutableConfig
  ) external;

  /**
    * @notice Configures an existing vamm 
    * @dev Only configures mutable vamm variables
    */
  function configureVamm(uint128 _marketId, uint32 _maturityTimestamp, VammConfiguration.Mutable calldata _config)
    external;

  /**
    * @param _marketId Id of the market for which we want to increase the number of observations
    * @param _maturityTimestamp Timestamp at which the given market matures
    * @param _observationCardinalityNext The desired minimum number of observations for the pool to store
    */
  function increaseObservationCardinalityNext(uint128 _marketId, uint32 _maturityTimestamp, uint16 _observationCardinalityNext)
    external;
  
  /**
     * @notice Get dated IRS Adjusted TWAP for the purposes of unrealized pnl calculation in the portfolio (see Portfolio.sol)
     * @param marketId Id of the market for which we want to retrieve the dated IRS TWAP
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param orderSize The order size to use when adjusting the price for price impact or spread. No adjustment is applied if 0.
     * @param lookbackWindow Number of seconds in the past from which to calculate the time-weighted means
     * @return datedIRSTwap Time Weighted Average Fixed Rate (average = geometric mean)
     */
  function getAdjustedDatedIRSTwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow) 
    external view returns (UD60x18 datedIRSTwap);

  /**
    * @notice Get dated IRS TWAP
    * @param marketId Id of the market for which we want to retrieve the dated IRS TWAP
    * @param maturityTimestamp Timestamp at which a given market matures
    * @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the boolean params is true because it used to indicate the direction of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
    * @param lookbackWindow Number of seconds in the past from which to calculate the time-weighted means
    * @param adjustForPriceImpact Whether or not to adjust the returned price by the VAMM's configured spread.
    * @param adjustForSpread Whether or not to adjust the returned price by the VAMM's configured spread.
    * @return datedIRSTwap Time Weighted Average Fixed Rate (average = geometric mean)
    */
  function getDatedIRSTwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow, bool adjustForPriceImpact,  bool adjustForSpread) 
    external view returns (UD60x18 datedIRSTwap);

  ///////////// GETTERS /////////////

  /**
    * @notice Returns vamm configuration
    */
  function getVammConfig(uint128 _marketId, uint32 _maturityTimestamp)
    external view returns (
      VammConfiguration.Immutable memory _config,
      VammConfiguration.Mutable memory _mutableConfig
    );

  function getVammSqrtPriceX96(uint128 _marketId, uint32 _maturityTimestamp)
    external view returns (uint160 sqrtPriceX96);

  function getVammTick(uint128 _marketId, uint32 _maturityTimestamp)
    external view returns (int24 tick);

  function getVammTickInfo(uint128 _marketId, uint32 _maturityTimestamp, int24 tick)
    external view returns (Tick.Info memory tickInfo);

  function getVammTickBitmap(uint128 _marketId, uint32 _maturityTimestamp, int16 wordPosition)
    external view returns (uint256);
  
  function getVammLiquidity(uint128 _marketId, uint32 _maturityTimestamp)
    external view returns (uint128 liquidity);

  function getVammPositionsInAccount(uint128 _marketId, uint32 _maturityTimestamp, uint128 accountId)
    external view returns (uint128[] memory positionsInAccount);

  function getVammTrackerQuoteTokenGrowthGlobalX128(uint128 _marketId, uint32 _maturityTimestamp)
    external view returns (int256 trackerQuoteTokenGrowthGlobalX128);
  
  function getVammTrackerBaseTokenGrowthGlobalX128(uint128 _marketId, uint32 _maturityTimestamp)
    external view returns (int256 trackerBaseTokenGrowthGlobalX128);
}