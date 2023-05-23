//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/vamm-math/VAMMBase.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Tracks LP positions
 */
library LPPosition {
    using LPPosition for LPPosition.Data;
    using SafeCastU128 for uint128;

    error PositionNotFound();
    error PositionAlreadyExists(uint128 positionId);

    struct Data {
        /** 
        * @dev position's account id
        */
        uint128 accountId;
        /** 
        * @dev amount of liquidity per tick in this position
        */
        uint128 liquidity;
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
        int256 trackerFixedTokenUpdatedGrowth;
        /** 
        * @dev variable token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 trackerBaseTokenUpdatedGrowth;
        /** 
        * @dev current Fixed Token balance of the position, 1 fixed token can be redeemed for 1% APY * (annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 trackerFixedTokenAccumulated;
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
    function updateTrackers(
        Data storage self,
        int256 trackerFixedTokenUpdatedGrowth,
        int256 trackerBaseTokenUpdatedGrowth,
        int256 deltaTrackerFixedTokenAccumulated,
        int256 deltaTrackerBaseTokenAccumulated
    ) internal {

        if (self.accountId == 0) {
            revert PositionNotFound();
        }
        self.trackerFixedTokenUpdatedGrowth = trackerFixedTokenUpdatedGrowth;
        self.trackerBaseTokenUpdatedGrowth = trackerBaseTokenUpdatedGrowth;
        self.trackerFixedTokenAccumulated += deltaTrackerFixedTokenAccumulated;
        self.trackerBaseTokenAccumulated += deltaTrackerBaseTokenAccumulated;
    }

    function updateLiquidity(Data storage self, int128 liquidityDelta) internal {
        if (self.accountId == 0) {
            revert PositionNotFound();
        }
        self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
    }

    /// @dev Private but labelled internal for testability.
    function _ensurePositionOpened(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper
    ) 
        internal
        returns (Data storage position, bool newlyCreated){

        uint128 positionId = getPositionId(accountId, tickLower, tickUpper);

        position = load(positionId);

        if(position.accountId != 0) {
            return (position, false);
        }

        return (create(accountId, tickLower, tickUpper), true);
    }

    function getUpdatedPositionBalances(
        Data memory self,
        int256 fixedTokenGrowthInsideX128,
        int256 baseTokenGrowthInsideX128
    )
        internal view returns (int256, int256) {

        if (self.accountId == 0) {
            revert PositionNotFound();
        }

        (int256 fixedTokenDelta, int256 baseTokenDelta) = calculateFixedAndVariableDelta(
            self,
            fixedTokenGrowthInsideX128,
            baseTokenGrowthInsideX128
        );

        return (
            self.trackerFixedTokenAccumulated + fixedTokenDelta,
            self.trackerBaseTokenAccumulated + baseTokenDelta
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

    /// @notice Returns Fixed and Variable Token Deltas
    /// @param self position info struct represeting a liquidity provider
    /// @param fixedTokenGrowthInsideX128 fixed token growth per unit of liquidity as of now (in wei)
    /// @param baseTokenGrowthInsideX128 variable token growth per unit of liquidity as of now (in wei)
    /// @return _fixedTokenDelta = (fixedTokenGrowthInside-fixedTokenGrowthInsideLast) * liquidity of a position
    /// @return _baseTokenDelta = (baseTokenGrowthInside-baseTokenGrowthInsideLast) * liquidity of a position
    function calculateFixedAndVariableDelta(
        Data memory self,
        int256 fixedTokenGrowthInsideX128,
        int256 baseTokenGrowthInsideX128
    )
        internal
        view
        returns (int256 _fixedTokenDelta, int256 _baseTokenDelta)
    {

        int256 fixedTokenGrowthInsideDeltaX128 = fixedTokenGrowthInsideX128 -
            self.trackerFixedTokenUpdatedGrowth;

        _fixedTokenDelta = FullMath.mulDivSigned(
            fixedTokenGrowthInsideDeltaX128,
            self.liquidity,
            FixedPoint128.Q128
        );

        int256 baseTokenGrowthInsideDeltaX128 = baseTokenGrowthInsideX128 -
                self.trackerBaseTokenUpdatedGrowth;

        _baseTokenDelta = FullMath.mulDivSigned(
            baseTokenGrowthInsideDeltaX128,
            self.liquidity,
            FixedPoint128.Q128
        );
    }
}
