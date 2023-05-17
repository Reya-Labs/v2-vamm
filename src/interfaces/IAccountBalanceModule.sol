// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

interface IAccountBalanceModule {
  /**
    * @notice Calculates base and quote token balances of all LP positions in the account.
    * @notice They represent the amount that has been locked in swaps
    * @param marketId Id of the market to look at 
    * @param maturityTimestamp Timestamp at which a given market matures
    * @param accountId Id of the `Account` to look at
  */
  function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
      external
      view
      returns (int256 baseBalancePool, int256 quoteBalancePool);

  /**
    * @notice Returns the base amount minted by an account but not used in a swap.
    * @param marketId Id of the market to look at 
    * @param maturityTimestamp Timestamp at which a given market matures
    * @param accountId Id of the `Account` to look at
    * @return unfilledBaseLong Base amount left unused to the right of the current tick
    * @return unfilledBaseShort Base amount left unused to the left of the current tick
  */
  function getAccountUnfilledBases(
      uint128 marketId,
      uint32 maturityTimestamp,
      uint128 accountId
  )
      external
      view
      returns (uint256 unfilledBaseLong, uint256 unfilledBaseShort);
}