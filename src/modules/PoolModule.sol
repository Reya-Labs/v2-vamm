// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { UD60x18, ZERO } from "@prb/math/UD60x18.sol";

import "../interfaces/IPoolModule.sol";
import "../storage/DatedIrsVamm.sol";
import "../storage/PoolConfiguration.sol";
import "@voltz-protocol/products-dated-irs/src/interfaces/IProductIRSModule.sol";
import "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import "@voltz-protocol/core/src/storage/AccountRBAC.sol";

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/// @title Interface a Pool needs to adhere.
contract PoolModule is IPoolModule {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU128 for uint128;

    /// @notice returns a human-readable name for a given pool
    function name() external view override returns (string memory) {
        return "Dated Irs Pool";
    }

    /**
     * @inheritdoc IPoolModule
     */
    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 sqrtPriceLimitX96
    )
        external override
        returns (int256 executedBaseAmount, int256 executedQuoteAmount) {
        
        if (msg.sender != PoolConfiguration.load().productAddress) {
            revert NotAuthorized(msg.sender, "executeDatedTakerOrder");
        }
        PoolConfiguration.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        VAMMBase.SwapParams memory swapParams;
        swapParams.amountSpecified = -baseAmount;
        swapParams.sqrtPriceLimitX96 = sqrtPriceLimitX96 == 0
                ? (
                    baseAmount > 0 // VT
                        ? vamm.mutableConfig.minSqrtRatio + 1
                        : vamm.mutableConfig.maxSqrtRatio - 1
                )
                : sqrtPriceLimitX96;

        (executedQuoteAmount, executedBaseAmount) = vamm.vammSwap(swapParams);
    }

    /**
     * @inheritdoc IPoolModule
     */
    function initiateDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        external override returns (uint256 fee, uint256 im)
    {
        address productAddress = PoolConfiguration.load().productAddress;

        IProductIRSModule irsProduct = IProductIRSModule(productAddress);

        IAccountModule(
            irsProduct.getCoreProxyAddress()
        ).onlyAuthorized(accountId, AccountRBAC._ADMIN_PERMISSION, msg.sender);

        PoolConfiguration.whenNotPaused();
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        vamm.executeDatedMakerOrder(accountId, tickLower, tickUpper, liquidityDelta);

        if ( liquidityDelta > 0) {
            (fee, im) = irsProduct.propagateMakerOrder(
                accountId,
                marketId,
                maturityTimestamp,
                VAMMBase.baseAmountFromLiquidity(
                    liquidityDelta,
                    vamm.getSqrtRatioAtTickSafe(tickLower),
                    vamm.getSqrtRatioAtTickSafe(tickUpper)
                )
            );
       }
       
    }

    /**
     * @inheritdoc IPoolModule
     */
    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external override
        returns (int256 closeUnfilledBasePool) {

        if (msg.sender != PoolConfiguration.load().productAddress) {
            revert NotAuthorized(msg.sender, "executeDatedTakerOrder");
        }
        PoolConfiguration.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        uint128[] memory positions = vamm.vars.positionsInAccount[accountId];

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data memory position = LPPosition.load(positions[i]);
            vamm.executeDatedMakerOrder(
                accountId, 
                position.tickLower,
                position.tickUpper,
                -position.liquidity.toInt()
            );
            closeUnfilledBasePool += position.liquidity.toInt();
        }
        
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPoolModule).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
