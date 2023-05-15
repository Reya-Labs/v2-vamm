// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../interfaces/IPoolConfigurationModule.sol";

import "../storage/PoolConfiguration.sol";
import "@voltz-protocol/util-modules/src/modules/FeatureFlagModule.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

contract PoolConfigurationModule is IPoolConfigurationModule {
  using PoolConfiguration for PoolConfiguration.Data;

  bytes32 private constant _PAUSER_FEATURE_FLAG = "registerProduct";

  function setPauseState(bool paused) external override {
    FeatureFlag.ensureAccessToFeature(_PAUSER_FEATURE_FLAG);
    PoolConfiguration.load().setPauseState(paused);
  }

  function setProductAddress(address poolAddress) external override {
    OwnableStorage.onlyOwner();
    PoolConfiguration.load().setProductAddress(poolAddress);
  }
}