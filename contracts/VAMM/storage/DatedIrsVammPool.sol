// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./DatedIrsVamm.sol";
import "../libraries/VAMMBase.sol";
import "../../ownership/OwnableStorage.sol";

/// @title Interface a Pool needs to adhere.
library DatedIrsVammPool {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using VAMMBase for bool;

    struct Data {
        /**
         * @dev Numeric identifier for the vamm pool. Must be unique.
         * @dev There cannot be a vamm with id zero (See VAMMCreator.create()). Id zero is used as a null vamm reference.
         */
        uint128 id; // TODO: delete if not needed?
        /**
         * @dev Text identifier for the vamm.
         *
         * Not required to be unique.
         */
        string name; // TODO: delete if not needed? Maybe name should be constructed programmatically
        /**
         * @dev Creator of the vamm, which has configuration access rights for the vamm.
         *
         * See onlyVAMMOwner.
         */
        address owner; // TODO: use this (or somethng else) ao auth all activity

        mapping(address => bool) pauser;
        bool paused;
    }

    function load(uint128 id) internal pure returns (Data storage self) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVAMMPool", id));
        assembly {
            self.slot := s
        }
    }

    function changePauser(Data storage self, address account, bool permission) internal {
      // not sure if msg.sender is the caller
      OwnableStorage.onlyOwner();
      self.pauser[account] = permission;
    }

    function setPauseState(Data storage self, bool state) internal { // TODO: move to DatedIRSVammPool?
        require(self.pauser[msg.sender], "only pauser");
        self.paused = state;
    }

    // TODO: add function for creating a new VAMM instance, calling through to DatedIrsVamm.createByMaturityAndMarket

    /// @dev note, a pool needs to have this interface to enable account closures initiated by products
    function executeDatedTakerOrder(
        Data storage self,
        uint128 marketId,
        uint256 maturityTimestamp,
        int256 baseAmount,
        uint160 priceLimit
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount){
        self.paused.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        VAMMBase.SwapParams memory swapParams;
        swapParams.amountSpecified = baseAmount;
        swapParams.sqrtPriceLimitX96 = priceLimit == 0
                ? (
                    baseAmount < 0 // VT
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1
                )
                : priceLimit;
        swapParams.tickLower = TickMath.MIN_TICK;
        swapParams.tickUpper = TickMath.MAX_TICK - 1;

        (executedBaseAmount, executedQuoteAmount) = vamm.vammSwap(swapParams);
    }

    /**
     * @notice Executes a dated maker order against a vamm that provided liquidity to a given marketId & maturityTimestamp pair
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param marketId Id of the market in which the lp wants to provide liqudiity
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param fixedRateLower Lower Fixed Rate of the range order
     * @param fixedRateUpper Upper Fixed Rate of the range order
     * @param requestedBaseAmount Requested amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     * @param executedBaseAmount Executed amount of notional provided to a given vamm in terms of the virtual base tokens of the
     * market
     */
    function initiateDatedMakerOrder(
        Data storage self,
        uint128 accountId,
        uint128 marketId,
        uint256 maturityTimestamp,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 requestedBaseAmount
    )
        external
        returns (int256 executedBaseAmount){ // TODO: returning 256 for 128 request seems wrong
       self.paused.whenNotPaused();
        
       DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
       return vamm.executeDatedMakerOrder(accountId, fixedRateLower, fixedRateUpper, requestedBaseAmount);
    }

    function getAccountFilledBalances(
        uint128 marketId,
        uint256 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountFilledBalances(accountId);
    }

    function getAccountUnfilledBases(
        uint128 marketId,
        uint256 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 unfilledBaseLong, int256 unfilledBaseShort)
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountUnfilledBases(accountId);
    }
}
