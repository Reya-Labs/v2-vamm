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
        mapping(address => bool) pauser;
        bool paused;
    }

    function load(uint128 id) internal pure returns (Data storage self) {
        require(id != 0, "ID0"); // TODO: custom error
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVAMMPool", id));
        assembly {
            self.slot := s
        }
    }

    event Pauser(address account, bool isNowPauser);

    function changePauser(Data storage self, address account, bool permission) external {
      OwnableStorage.onlyOwner();
      self.pauser[account] = permission;
      emit Pauser(account, permission);
    }

    event PauseState(bool newPauseState);

    function setPauseState(Data storage self, bool state) external {
        require(self.pauser[msg.sender], "only pauser");
        self.paused = state;
        emit PauseState(state);
    }

    event VammCreated(
        uint128 indexed marketId,
        uint256 indexed maturityTimestamp,
        uint160 sqrtPriceX96,
        int24 tickSpacing,
        uint128 maxLiquidityPerTick,
        int24 tick,
        DatedIrsVamm.Config _config);

    function createVamm(uint128 _marketId, uint256 _maturityTimestamp,  uint160 _sqrtPriceX96, int24 _tickSpacing, DatedIrsVamm.Config calldata _config)
    external
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.create(_marketId, _maturityTimestamp, _sqrtPriceX96, _tickSpacing, _config);
        emit VammCreated(
            _marketId,
            _maturityTimestamp,
            _sqrtPriceX96,
            _tickSpacing,
            vamm._maxLiquidityPerTick,
            vamm._vammVars.tick,
            _config);
    }

    event VammConfigUpdated(
        uint128 _marketId,
        uint256 _maturityTimestamp,
        DatedIrsVamm.Config _config);

    function configureVamm(uint128 _marketId, uint256 _maturityTimestamp, DatedIrsVamm.Config calldata _config)
    external
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        vamm.configure(_config);
        emit VammConfigUpdated(_marketId, _maturityTimestamp, _config);
    }

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
        // TODO: authentication!
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
        returns (int256 executedBaseAmount){ // TODO: returning 256 for 128 request seems wrong?
       self.paused.whenNotPaused();
        // TODO: authentication!
        
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
         // TODO: not a view function because it propagates a position. Hard to be sure that more state writes won't creep in, so as such should we authenticate?         
        
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
        // TODO: not a view function because it propagates a position. Hard to be sure that more state writes won't creep in, so as such should we authenticate?         
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountUnfilledBases(accountId);
    }
}
