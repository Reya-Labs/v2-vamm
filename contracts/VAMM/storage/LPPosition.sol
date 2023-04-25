//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../libraries/VAMMBase.sol";

/**
 * @title Tracks LP positions
 */
library LPPosition {
    using LPPosition for LPPosition.Data;

    error PositionNotFound();
    error PositionAlreadyExists(uint128 positionId);

    struct Data {
        /** 
        * @dev position's account id
        */
        uint128 accountId;
        /** 
        * @dev position notional amount
        */
        int128 baseAmount;
        /** 
        * @dev lower tick boundary of the position
        */
        int24 tickLower;
        /** 
        * @dev upper tick boundary of the position
        */
        int24 tickUpper;
        /** 
        * @dev fixed token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 trackerVariableTokenUpdatedGrowth;
        /** 
        * @dev variable token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 trackerBaseTokenUpdatedGrowth;
        /** 
        * @dev current Fixed Token balance of the position, 1 fixed token can be redeemed for 1% APY * (annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 trackerVariableTokenAccumulated;
        /** 
        * @dev current Variable Token Balance of the position, 1 variable token can be redeemed for underlyingPoolAPY*(annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 trackerBaseTokenAccumulated;
    }

    /**
     * @dev Loads the LPPosition object for the given position Id
     */
    function load(uint128 positionId) internal pure returns (Data storage position) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.LPPosition", positionId));
        assembly {
            position.slot := s
        }
    }

    /**
     * @dev Creates a position
     */
    function create(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (Data storage position){

        uint128 positionId = getPositionId(accountId, tickLower, tickUpper);

        position = load(positionId);

        if (position.accountId != 0) {
            revert PositionAlreadyExists(positionId);
        }

        position.accountId = accountId;
        position.tickUpper = tickUpper;
        position.tickLower = tickLower;
    }

    // todo: currently not used
    function setTrackers(
        uint128 positionId,
        int256 trackerVariableTokenUpdatedGrowth,
        int256 trackerBaseTokenUpdatedGrowth,
        int256 trackerVariableTokenAccumulated,
        int256 trackerBaseTokenAccumulated
    ) internal {
        Data storage position = load(positionId);

        if (position.accountId == 0) {
            revert PositionNotFound();
        }
        position.trackerVariableTokenUpdatedGrowth = trackerVariableTokenUpdatedGrowth;
        position.trackerBaseTokenUpdatedGrowth = trackerBaseTokenUpdatedGrowth;
        position.trackerVariableTokenAccumulated = trackerVariableTokenAccumulated;
        position.trackerBaseTokenAccumulated = trackerBaseTokenAccumulated;
    }

    function updateBaseAmount(Data storage self, int128 baseAmount) internal {
        if (self.accountId == 0) {
            revert PositionNotFound();
        }
        self.baseAmount += baseAmount;
    }

    /// @dev Private but labelled internal for testability.
    function _ensurePositionOpened(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper
    ) 
        internal
        returns (Data storage position){

        uint128 positionId = getPositionId(accountId, tickLower, tickUpper);

        position = load(positionId);

        if(position.accountId != 0) {
            return position;
        }

        position = create(accountId, tickLower, tickUpper);
    }

    function getUpdatedPositionBalances(
        Data memory self,
        int256 trackerVariableTokenGlobalGrowth,
        int256 trackerBaseTokenGlobalGrowth
    )
        internal pure returns (int256, int256) {

        require(self.accountId != 0, "Missing position"); // TODO: custom error

        int256 trackerVariableTokenDeltaGrowth =
                trackerVariableTokenGlobalGrowth - self.trackerVariableTokenUpdatedGrowth;
        int256 trackerBaseTokenDeltaGrowth =
                trackerBaseTokenGlobalGrowth - self.trackerBaseTokenUpdatedGrowth;

        int256 averageBase = VAMMBase.basePerTick(
            self.tickLower,
            self.tickUpper,
            self.baseAmount
        );

        return (
            self.trackerVariableTokenAccumulated + trackerVariableTokenDeltaGrowth * averageBase,
            self.trackerBaseTokenAccumulated + trackerBaseTokenDeltaGrowth * averageBase
        );
    }

    /**
     * @notice Returns the positionId that such a position would have, should it exist. Does not check for existence.
     */
    function getPositionId(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        pure
        returns (uint128){

        return uint128(uint256(keccak256(abi.encodePacked(accountId, tickLower, tickUpper))));
    }
}
