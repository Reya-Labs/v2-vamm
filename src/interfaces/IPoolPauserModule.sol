// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface IPoolPauserModule {
  /// @dev todo docs
  function setPauseState(bool paused) external;
}