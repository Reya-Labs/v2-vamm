// SPDX-License-Identifier: Apache-2.0

pragma solidity >=0.8.13;

interface CustomErrors {
   
   /// @dev Thrown when a zero address was passed as a function parameter (0x0000000000000000000000000000000000000000).
   error ZeroAddress();

   /// @dev Thrown when a change is expected but none is detected.
   error NoChange();

   /// The operation is not authorized by the executing adddress
   error Unauthorized(address unauthorizedAddr);

   /// Only one VAMM can exist for any given {market, maturity}
   error MarketAndMaturityCombinaitonAlreadyExists(uint128 marketId, uint256 maturityTimestamp);

   /// No VAMM currently exists for the specified {market, maturity}
   error MarketAndMaturityCombinaitonNotSupported(uint128 marketId, uint256 maturityTimestamp);
//
//    /// Margin delta must not equal zero
//    error InvalidMarginDelta();
//
//
//    error closeToOrBeyondMaturity();
//
//    /// @dev There are not enough funds available for the requested operation
//    error NotEnoughFunds(uint256 requested, uint256 available);
//
//    /// @dev The two values were expected to have oppostite sigs, but do not
//    error ExpectedOppositeSigns(int256 amount0, int256 amount1);
//
   /// @dev If the sqrt price of the vamm is non-zero before a vamm is initialized, it has already been initialized. Initialization can only be done once.
   error ExpectedSqrtPriceZeroBeforeInit(uint160 sqrtPriceX96);

   /// @dev If the sqrt price of the vamm is zero, this makes no sense and does not allow sqrtPriceX96 to double as an "already initialized" flag.
      error ExpectedNonZeroSqrtPriceForInit(uint160 sqrtPriceX96);
//
//    /// @dev Error which ensures the liquidity delta is positive if a given LP wishes to mint further liquidity in the vamm
//    error LiquidityDeltaMustBePositiveInMint(uint128 amount);
//
//    /// @dev Error which ensures the liquidity delta is positive if a given LP wishes to burn liquidity in the vamm
//    error LiquidityDeltaMustBePositiveInBurn(uint128 amount);
//
   /// @dev Error which ensures the amount of notional specified when initiating an IRS contract (via the swap function in the vamm) is non-zero
   error IRSNotionalAmountSpecifiedMustBeNonZero();
//
   /// @dev Error which ensures the VAMM is unlocked
   error CanOnlyTradeIfUnlocked();

   /// @dev Error which ensures the VAMM is unlocked
   error CanOnlyUnlockIfLocked();

   error MaturityMustBeInFuture(uint256 currentTime, uint256 requestedMaturity);
}
