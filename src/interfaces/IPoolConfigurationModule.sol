// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface IPoolConfigurationModule {

  /// @notice Pausing or unpausing trading activity on the vamm
  /// @param paused True if the desire is to pause the vamm, and false inversely
  function setPauseState(bool paused) external;

  /// @notice Setting the product (instrument) address
  /// @param productAddress Address of the product proxy
  function setProductAddress(address productAddress) external;

  /// @notice Setting positions per account limit
  /// @param limit Maximum number of positions an acccount can have
  function setPositionsPerAccountLimit(uint256 limit) external;
}