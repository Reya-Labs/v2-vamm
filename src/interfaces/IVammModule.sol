// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/vamm-math/VammConfiguration.sol";

interface IVammModule {
  /// @dev Emitted when vamm configurations are updated
  event VammConfigUpdated(
      uint128 _marketId,
      VammConfiguration.Mutable _config
  );

  /// @dev Emitted when a new vamm is created and initialized
  event VammCreated(
      uint128 _marketId,
      int24 tick,
      VammConfiguration.Immutable _config,
      VammConfiguration.Mutable _mutableConfig
  );

  /**
    * @notice registers a new vamm with the specified configurationsa and initializes the price
    */
  function createVamm(uint128 _marketId,  uint160 _sqrtPriceX96, VammConfiguration.Immutable calldata _config, VammConfiguration.Mutable calldata _mutableConfig)
    external;

  /**
    * @notice Configures an existing vamm 
    * @dev Only configures mutable vamm variables
    */
  function configureVamm(uint128 _marketId, uint256 _maturityTimestamp, VammConfiguration.Mutable calldata _config)
    external;
  
  /**
     * @notice Get dated IRS TWAP for the purposes of unrealized pnl calculation in the portfolio (see Portfolio.sol)
     * @param marketId Id of the market for which we want to retrieve the dated IRS TWAP
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the boolean params is true because it used to indicate the direction of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
     * @param lookbackWindow Whether or not to adjust the returned price by the VAMM's configured spread.
     * @return datedIRSTwap Time Weighted Average Fixed Rate (average = geometric mean)
     */
  function getAdjustedDatedIRSTwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow) 
    external view returns (UD60x18 datedIRSTwap);

  /**
    * @notice Get dated IRS TWAP
    * @param marketId Id of the market for which we want to retrieve the dated IRS TWAP
    * @param maturityTimestamp Timestamp at which a given market matures
    * @param lookbackWindow Number of seconds in the past from which to calculate the time-weighted means
    * @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the boolean params is true because it used to indicate the direction of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
    * @param adjustForPriceImpact Whether or not to adjust the returned price by the VAMM's configured spread.
    * @param adjustForSpread Whether or not to adjust the returned price by the VAMM's configured spread.
    * @return datedIRSTwap Time Weighted Average Fixed Rate (average = geometric mean)
    */
  function getDatedIRSTwap(uint128 marketId, uint32 maturityTimestamp, uint32 lookbackWindow, int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread) 
    external view returns (UD60x18 datedIRSTwap);
}