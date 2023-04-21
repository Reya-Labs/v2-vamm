// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./DatedIrsVamm.sol";
import "../libraries/VAMMBase.sol";
import "../../ownership/OwnableStorage.sol";
import "../libraries/VammConfiguration.sol";
import "./PoolPauser.sol";

/// @title Interface a Pool needs to adhere.
library DatedIrsVammPool {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using VAMMBase for bool;
    using PoolPauser for PoolPauser.Data;

    struct Data {
        mapping(address => bool) pauser;
        bool paused;
    }

    function load() internal pure returns (Data storage self) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVAMMPool"));
        assembly {
            self.slot := s
        }
    }

    event Pauser(address account, bool isNowPauser);

    function changePauser(address account, bool permission) external {
      OwnableStorage.onlyOwner();
      DatedIrsVammPool.load().pauser[account] = permission;
      emit Pauser(account, permission);
    }

    event PauseState(bool newPauseState);

    function setPauseState(bool state) external {
        Data storage self = DatedIrsVammPool.load();
        require(self.pauser[msg.sender], "only pauser");
        self.paused = state;
        emit PauseState(state);
    }

    event VammCreated(
        uint128 _marketId,
        int24 tick,
        VammConfiguration.Immutable _config,
        VammConfiguration.Mutable _mutableConfig
    );

    function createVamm(uint128 _marketId,  uint160 _sqrtPriceX96, VammConfiguration.Immutable calldata _config, VammConfiguration.Mutable calldata _mutableConfig)
    external
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.create(_marketId, _sqrtPriceX96, _config, _mutableConfig);
        emit VammCreated(
            _marketId,
            vamm.vars.tick,
            _config,
            _mutableConfig
        );
    }

    event VammConfigUpdated(
        uint128 _marketId,
        VammConfiguration.Mutable _config
    );

    function configureVamm(uint128 _marketId, uint256 _maturityTimestamp, VammConfiguration.Mutable calldata _config)
    external
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        vamm.configure(_config);
        emit VammConfigUpdated(_marketId, _config);
    }

    /// @dev note, a pool needs to have this interface to enable account closures initiated by products
    function executeDatedTakerOrder(
        uint128 marketId,
        uint256 maturityTimestamp,
        int256 baseAmount,
        uint160 priceLimit
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount){
        // TODO: authentication!
        PoolPauser.load().whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        IVAMMBase.SwapParams memory swapParams;
        swapParams.baseAmountSpecified = baseAmount;
        swapParams.sqrtPriceLimitX96 = priceLimit == 0
                ? (
                    baseAmount < 0 // VT
                        ? TickMath.MIN_SQRT_RATIO + 1
                        : TickMath.MAX_SQRT_RATIO - 1
                )
                : priceLimit;

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
        uint128 accountId,
        uint128 marketId,
        uint256 maturityTimestamp,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 requestedBaseAmount
    )
        external
        returns (int256 executedBaseAmount){ // TODO: returning 256 for 128 request seems wrong?
       
        PoolPauser.load().whenNotPaused();
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
        view
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
        view
        returns (int256 unfilledBaseLong, int256 unfilledBaseShort)
    {
        // TODO: not a view function because it propagates a position. Hard to be sure that more state writes won't creep in, so as such should we authenticate?         
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountUnfilledBases(accountId);
    }
}
