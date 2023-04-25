// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../storage/DatedIrsVamm.sol";

import "@openzeppelin/contracts/utils/math/SignedMath.sol";

contract AccountModule {
  using DatedIrsVamm for DatedIrsVamm.Data;
  
   function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (int256 baseBalancePool, int256 quoteBalancePool){     
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountFilledBalances(accountId);
    
    }

    function getAccountUnfilledBases(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (uint256 unfilledBaseLong, uint256 unfilledBaseShort) {      
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        (int256 _unfilledBaseLong, int256 _unfilledBaseShort) = vamm.getAccountUnfilledBases(accountId);

        // TODO: we decided to have the unfilled balances unsigned, considering the name already points to a direction
        // to avoid abs(), adjustments are required to getAccountUnfilledBases
        unfilledBaseLong = SignedMath.abs(_unfilledBaseLong);
        unfilledBaseShort = SignedMath.abs(_unfilledBaseShort);
    }
}