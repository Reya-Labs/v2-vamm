// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface IAccountBalanceModule {
  /// @dev todo docs
  function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
      external
      view
      returns (int256 baseBalancePool, int256 quoteBalancePool);

  /// @dev todo docs
  function getAccountUnfilledBases(
      uint128 marketId,
      uint32 maturityTimestamp,
      uint128 accountId
  )
      external
      view
      returns (uint256 unfilledBaseLong, uint256 unfilledBaseShort);
}