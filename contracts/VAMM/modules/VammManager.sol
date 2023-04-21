// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../storage/DatedIrsVamm.sol";
import "../storage/DatedIrsVammPool.sol";
/**
 * @title Module for configuring a market
 * @dev See IMarketConfigurationModule.
 */
contract VammManager {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using DatedIrsVammPool for DatedIrsVammPool.Data;

    event Pauser(address account, bool isNowPauser);

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

    function changePauser(address account, bool permission) external {
      OwnableStorage.onlyOwner();
      DatedIrsVammPool.load().pauser[account] = permission;
      emit Pauser(account, permission);
    }

    event PauseState(bool newPauseState);

    function setPauseState(bool state) external {
        DatedIrsVammPool.Data storage self = DatedIrsVammPool.load();
        require(self.pauser[msg.sender], "only pauser");
        self.paused = state;
        emit PauseState(state);
    }

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
}
