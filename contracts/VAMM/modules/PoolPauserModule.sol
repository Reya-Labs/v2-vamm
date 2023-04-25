// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../interfaces/IPoolPauserModule.sol";

import "../storage/PoolPauser.sol";
import "../../../utils/feature-flag/FeatureFlag.sol";

contract PoolPauserModule is IPoolPauserModule {
  using PoolPauser for PoolPauser.Data;

  bytes32 private constant _PAUSER_FEATURE_FLAG = "registerProduct";

  function setPauseState(bool paused) external override {
    FeatureFlag.ensureAccessToFeature(_PAUSER_FEATURE_FLAG);
    PoolPauser.load().setPauseState(paused);
  }
}