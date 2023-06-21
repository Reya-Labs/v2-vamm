// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../interfaces/IVammModule.sol";
import "../storage/DatedIrsVamm.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

/**
 * @title Module for configuring a market
 * @dev See IMarketConfigurationModule.
 */
contract VammModule is IVammModule {
    using DatedIrsVamm for DatedIrsVamm.Data;

    /**
     * @inheritdoc IVammModule
     */
    function createVamm(uint128 _marketId,  uint160 _sqrtPriceX96, VammConfiguration.Immutable calldata _config, VammConfiguration.Mutable calldata _mutableConfig)
    external override
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.create(_marketId, _sqrtPriceX96, _config, _mutableConfig);
        emit VammCreated(
            _marketId,
            vamm.vars.tick,
            _config,
            _mutableConfig,
            block.timestamp
        );
    }

    /**
     * @inheritdoc IVammModule
     */
    function configureVamm(uint128 _marketId, uint32 _maturityTimestamp, VammConfiguration.Mutable calldata _config)
    external override
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        vamm.configure(_config);
        emit VammConfigUpdated(_marketId, _config, block.timestamp);
    }

    /**
     * @inheritdoc IVammModule
     */
    function getAdjustedDatedIRSTwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow) 
        external view override returns (UD60x18 datedIRSTwap) 
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        datedIRSTwap = vamm.twap(lookbackWindow, orderSize, true, true);
    }

    /**
     * @inheritdoc IVammModule
     */
    function getDatedIRSTwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSize, uint32 lookbackWindow, bool adjustForPriceImpact,  bool adjustForSpread) 
        external view override returns (UD60x18 datedIRSTwap) 
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        datedIRSTwap = vamm.twap(lookbackWindow, orderSize, adjustForPriceImpact, adjustForSpread);
    }


    ////////// GETTERS //////////

    function getVammConfig(uint128 _marketId, uint32 _maturityTimestamp)
        external view override returns (
        VammConfiguration.Immutable memory _config,
        VammConfiguration.Mutable memory _mutableConfig
    ) {
         DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
         _config = vamm.immutableConfig;
         _mutableConfig = vamm.mutableConfig;
    }

    function getVammSqrtPriceX96(uint128 _marketId, uint32 _maturityTimestamp)
        external view override returns (uint160) {

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        return vamm.vars.sqrtPriceX96;
    }

    function getVammTick(uint128 _marketId, uint32 _maturityTimestamp)
        external view override returns (int24) {

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        return vamm.vars.tick;
    }

    function getVammTickInfo(uint128 _marketId, uint32 _maturityTimestamp, int24 tick)
        external view override returns (Tick.Info memory) {

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        return vamm.vars._ticks[tick];
    }

    function getVammTickBitmap(uint128 _marketId, uint32 _maturityTimestamp, int16 wordPosition)
        external view override returns (uint256) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        return vamm.vars._tickBitmap[wordPosition];
    }
    
    function getVammLiquidity(uint128 _marketId, uint32 _maturityTimestamp)
        external view override returns (uint128) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        return vamm.vars.liquidity;
    }

    function getVammPositionsInAccount(uint128 _marketId, uint32 _maturityTimestamp, uint128 accountId)
        external view override returns (uint128[] memory) {

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        return vamm.vars.positionsInAccount[accountId];
    }

    function getVammTrackerQuoteTokenGrowthGlobalX128(uint128 _marketId, uint32 _maturityTimestamp)
        external view override returns (int256) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        return vamm.vars.trackerQuoteTokenGrowthGlobalX128;
    }
    
    function getVammTrackerBaseTokenGrowthGlobalX128(uint128 _marketId, uint32 _maturityTimestamp)
        external view override returns (int256) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        return vamm.vars.trackerBaseTokenGrowthGlobalX128;
    }
}
