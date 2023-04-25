// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../storage/DatedIrsVamm.sol";
import "../../utils/owner-upgrade/OwnableStorage.sol";

/**
 * @title Module for configuring a market
 * @dev See IMarketConfigurationModule.
 */
contract VammModule {
    using DatedIrsVamm for DatedIrsVamm.Data;

    event VammConfigUpdated(
        uint128 _marketId,
        VammConfiguration.Mutable _config
    );

    event VammCreated(
        uint128 _marketId,
        int24 tick,
        VammConfiguration.Immutable _config,
        VammConfiguration.Mutable _mutableConfig
    );

    function createVamm(uint128 _marketId,  uint160 _sqrtPriceX96, VammConfiguration.Immutable calldata _config, VammConfiguration.Mutable calldata _mutableConfig)
    external
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.create(_marketId, _sqrtPriceX96, _config, _mutableConfig);
        emit VammCreated(
            _marketId,
            vamm.vars.tick,
            _config,
            _mutableConfig
        );
    }

    function configureVamm(uint128 _marketId, uint256 _maturityTimestamp, VammConfiguration.Mutable calldata _config)
    external
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        vamm.configure(_config);
        emit VammConfigUpdated(_marketId, _config);
    }

    function getAdjustedDatedIRSGwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow) external view returns (UD60x18 datedIRSGwap) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        datedIRSGwap = vamm.twap(lookbackWindow, orderSize, true, true);
    }

    /**
     * @notice Get dated irs gwap
     * @param marketId Id of the market for which we want to retrieve the dated irs gwap
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param lookbackWindow Number of seconds in the past from which to calculate the time-weighted means
     * @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the boolean params is true because it used to indicate the direction of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
     * @param adjustForPriceImpact Whether or not to adjust the returned price by the VAMM's configured spread.
     * @param adjustForSpread Whether or not to adjust the returned price by the VAMM's configured spread.
     * @return datedIRSGwap Geometric Time Weighted Average Fixed Rate
     */
    function getDatedIRSGwap(uint128 marketId, uint32 maturityTimestamp, uint32 lookbackWindow, int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread) external view returns (UD60x18 datedIRSGwap) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        datedIRSGwap = vamm.twap(lookbackWindow, orderSize, adjustForPriceImpact, adjustForSpread);
    }
}
