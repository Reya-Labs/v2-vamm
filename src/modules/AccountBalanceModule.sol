// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../interfaces/IAccountBalanceModule.sol";

import "../storage/DatedIrsVamm.sol";

import "oz/utils/math/SignedMath.sol";

contract AccountBalanceModule is IAccountBalanceModule {
  using DatedIrsVamm for DatedIrsVamm.Data;
  
   /**
     * @inheritdoc IAccountBalanceModule
     */
   function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        override
        returns (int256 baseBalancePool, int256 quoteBalancePool){     
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountFilledBalances(accountId);
    
    }

    /**
     * @inheritdoc IAccountBalanceModule
     */
    function getAccountUnfilledBaseandQuote(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        override
        returns (
            uint256 unfilledBaseLong,
            uint256 unfilledBaseShort,
            uint256 unfilledQuoteLong,
            uint256 unfilledQuoteShort
        ) {      
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        (unfilledBaseLong, unfilledBaseShort, unfilledQuoteLong, unfilledQuoteShort) = vamm.getAccountUnfilledBalances(accountId);
    }
}