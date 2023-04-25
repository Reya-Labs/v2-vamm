// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface IPoolPauserModule {
  function setPauseState(bool paused) external;
}