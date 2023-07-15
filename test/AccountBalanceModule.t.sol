// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../src/modules/AccountBalanceModule.sol";
import "./VoltzTest.sol";

contract ExtendedAccountBalanceModule is AccountBalanceModule, VoltzTest {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using PoolConfiguration for PoolConfiguration.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;

    int128 public constant BASE_AMOUNT_PER_LP = 50_000_000_000;
    uint128 public constant ACCOUNT_1 = 1;
    // TL -46055
    // TU -30285
    uint160 constant ACCOUNT_1_LOWER_SQRTPRICEX96 = uint160(1 * FixedPoint96.Q96 / 10); // 0.1 => price = 0.01 = 1%
    uint160 constant ACCOUNT_1_UPPER_SQRTPRICEX96 = uint160(22 * FixedPoint96.Q96 / 100); // 0.22 => price = 0.0484 = 4.84%
    int24 ACCOUNT_1_TICK_LOWER = TickMath.getTickAtSqrtRatio(ACCOUNT_1_LOWER_SQRTPRICEX96);
    int24 ACCOUNT_1_TICK_UPPER = TickMath.getTickAtSqrtRatio(ACCOUNT_1_UPPER_SQRTPRICEX96);

    function getVammConfig(uint128 marketId, uint32 maturityTimestamp) external view returns (VammConfiguration.Mutable memory, VammConfiguration.Immutable memory) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return (vamm.mutableConfig, vamm.immutableConfig);
    }

    function createTestVamm(uint128 _marketId,  uint160 _sqrtPriceX96, uint32[] calldata times, int24[] calldata observedTicks, VammConfiguration.Immutable calldata _config, VammConfiguration.Mutable calldata _mutableConfig) public {
        DatedIrsVamm.create(_marketId, _sqrtPriceX96, times, observedTicks, _config, _mutableConfig);
    }

    function increaseObservationCardinalityNext(uint128 _marketId, uint32 _maturityTimestamp, uint16 _observationCardinalityNext)
    public
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(_marketId, _maturityTimestamp);
        vamm.increaseObservationCardinalityNext(_observationCardinalityNext);
    }

    function setMakerPositionsPerAccountLimit(uint256 limit) public {
        PoolConfiguration.load().setMakerPositionsPerAccountLimit(limit);
    }

    function mockMakerOrder(uint128 marketId, uint32 maturityTimestamp) public returns (int128){
        int128 requestedLiquidityAmount = getLiquidityForBase(ACCOUNT_1_TICK_LOWER, ACCOUNT_1_TICK_UPPER, BASE_AMOUNT_PER_LP);
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        vamm.executeDatedMakerOrder(ACCOUNT_1,ACCOUNT_1_TICK_LOWER,ACCOUNT_1_TICK_UPPER, requestedLiquidityAmount);
        return BASE_AMOUNT_PER_LP;
    }

    function mockTakerOrderRight(uint128 marketId, uint32 maturityTimestamp) public returns (int256 quoteTokenDelta, int256 baseTokenDelta){
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        int256 amountSpecified =  500_000_000;

        DatedIrsVamm.SwapParams memory params = DatedIrsVamm.SwapParams({
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: ACCOUNT_1_UPPER_SQRTPRICEX96
        });

        uint256 _mockLiquidityIndex = 2;
        UD60x18 mockLiquidityIndex = convert(_mockLiquidityIndex);

        // Mock the liquidity index that is read during a swap
        vm.mockCall(0xAa73aA73Aa73Aa73AA73Aa73aA73AA73aa73aa73, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (quoteTokenDelta, baseTokenDelta) = vamm.vammSwap(params);
    }

    function getLiquidityForBase(
        int24 tickLower,
        int24 tickUpper,
        int256 baseAmount
    ) public pure returns (int128 liquidity) {

        // get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 absLiquidity = FullMath
                .mulDiv(uint256(baseAmount > 0 ? baseAmount : -baseAmount), VAMMBase.Q96, sqrtRatioBX96 - sqrtRatioAX96);

        return baseAmount > 0 ? absLiquidity.toInt().to128() : -(absLiquidity.toInt().to128());
    }
}

contract AccountBalanceModuleTest is VoltzTest {
    using SafeCastU256 for uint256;

    ExtendedAccountBalanceModule pool;

    uint256 _mockLiquidityIndex = 2;
    UD60x18 mockLiquidityIndex = convert(_mockLiquidityIndex);

    // Initial VAMM state
    // Picking a price that lies on a tick boundry simplifies the math to make some tests and checks easier
    int24 initialTick = -32191;
    uint160 initSqrtPriceX96 = TickMath.getSqrtRatioAtTick(initialTick); // price = ~0.04 = ~4%
    uint128 initMarketId = 1;
    int24 initTickSpacing = 1; // TODO: test with different tick spacing; need to adapt boundTicks()
    uint32 initMaturityTimestamp = uint32(block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR));
    address constant mockRateOracle = 0xAa73aA73Aa73Aa73AA73Aa73aA73AA73aa73aa73;
    VammConfiguration.Mutable internal mutableConfig = VammConfiguration.Mutable({
        priceImpactPhi: ud60x18(1e17), // 0.1
        priceImpactBeta: ud60x18(125e15), // 0.125
        spread: ud60x18(3e15), // 0.3%
        rateOracle: IRateOracle(mockRateOracle),
        minTick: MIN_TICK,
        maxTick: MAX_TICK
    });

    VammConfiguration.Immutable internal immutableConfig = VammConfiguration.Immutable({
        maturityTimestamp: initMaturityTimestamp,
        _maxLiquidityPerTick: type(uint128).max,
        _tickSpacing: initTickSpacing,
        marketId: initMarketId
    });

    uint32[] internal times;
    int24[] internal observedTicks;

    function setUp() public {
        pool = new ExtendedAccountBalanceModule();
        times = new uint32[](1);
        times[0] = uint32(block.timestamp);

        observedTicks = new int24[](1);
        observedTicks[0] = initialTick;
        
        pool.createTestVamm(initMarketId, initSqrtPriceX96, times, observedTicks, immutableConfig, mutableConfig);
//        pool.increaseObservationCardinalityNext(initMarketId, initMaturityTimestamp, 16);

        pool.setMakerPositionsPerAccountLimit(1);
    }

    function test_FilledBalances_UnknownPosition() public {
        (int256 baseBalancePool, int256 quoteBalancePool)  = pool.getAccountFilledBalances(initMarketId, initMaturityTimestamp, 162);
        assertEq(baseBalancePool, 0);
        assertEq(quoteBalancePool, 0);
    }

    function test_FilledBalances_UnknownMarket() public {
        vm.expectRevert();
        pool.getAccountFilledBalances(initMarketId, 22, 162);
    }

    function test_UnfilledBalances_UnknownMarket() public {
        vm.expectRevert();
         pool.getAccountUnfilledBaseAndQuote(34, initMaturityTimestamp, 162);
    }

    function test_UnfilledBalances_UnknownPosition() public {
        (uint256 unfilledBaseLong, uint256 unfilledBaseShort,,)= pool.getAccountUnfilledBaseAndQuote(initMarketId, initMaturityTimestamp, 162);
        assertEq(unfilledBaseLong, 0);
        assertEq(unfilledBaseShort, 0);
    }

    function test_FilledBalances() public {
        pool.mockMakerOrder(initMarketId, initMaturityTimestamp);
        (int256 quoteTokenDelta, int256 baseTokenDelta) = pool.mockTakerOrderRight(initMarketId, initMaturityTimestamp);

        (int256 baseBalancePool, int256 quoteBalancePool)  = pool.getAccountFilledBalances(initMarketId, initMaturityTimestamp, pool.ACCOUNT_1());
        assertAlmostEqual(baseBalancePool, -baseTokenDelta);
        assertAlmostEqual(quoteBalancePool, -quoteTokenDelta);
    }

    function test_UnfilledBalances() public {
        pool.mockMakerOrder(initMarketId, initMaturityTimestamp);
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(ud60x18(1e18)));
        (uint256 unfilledBaseLong, uint256 unfilledBaseShort,,)= pool.getAccountUnfilledBaseAndQuote(initMarketId, initMaturityTimestamp, pool.ACCOUNT_1());
        assertAlmostEqual((unfilledBaseLong + unfilledBaseShort).toInt(), int256(pool.BASE_AMOUNT_PER_LP()));
    }


}