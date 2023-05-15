// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface IPoolConfigurationModule {
  /// @dev todo docs
  function setPauseState(bool paused) external;

  function setProductAddress(address productAddress) external;
}