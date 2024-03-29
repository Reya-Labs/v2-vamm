// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../src/modules/VammModule.sol";
import "../src/modules/PoolConfigurationModule.sol";
import "./VoltzTest.sol";
import "forge-std/console2.sol";

contract ExtendedVammModule is VammModule {
    using Oracle for Oracle.Observation[65535];
    using DatedIrsVamm for DatedIrsVamm.Data;

    function setOwner(address account) external {
        OwnableStorage.Data storage ownable = OwnableStorage.load();
        ownable.owner = account;
    }

    function configureVamm(uint128 _vammId, VammConfiguration.Mutable calldata _mutableConfig) public {
        DatedIrsVamm.load(_vammId).configure(_mutableConfig);
    }

    function sqrtRatioMinAndMax(uint128 marketId, uint32 maturityTimestamp) external view returns (uint160, uint160) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return (vamm.minSqrtRatio, vamm.maxSqrtRatio);
    }

    function sqrtPriceX96(uint128 marketId, uint32 maturityTimestamp) external view returns (uint160) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.sqrtPriceX96;
    }

    function tick(uint128 marketId, uint32 maturityTimestamp) external view returns (int24) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.tick;
    }

    function observationIndex(uint128 marketId, uint32 maturityTimestamp) external view returns (uint16) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.observationIndex;
    }

    function observationCardinality(uint128 marketId, uint32 maturityTimestamp) external view returns (uint16) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.observationCardinality;
    }

    function observationCardinalityNext(uint128 marketId, uint32 maturityTimestamp) external view returns (uint16) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.observationCardinalityNext;
    }

    function unlocked(uint128 marketId, uint32 maturityTimestamp) external view returns (bool) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.unlocked;
    }

    function observations(uint128 marketId, uint32 maturityTimestamp, uint24 index) external view returns (Oracle.Observation memory) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.observations[index];
    }

    function positionsInAccount(uint128 marketId, uint32 maturityTimestamp, uint128 accountId) external view returns (uint128[] memory) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.positionsInAccount[accountId];
    }

    function liquidity(uint128 marketId, uint32 maturityTimestamp) external view returns (uint128) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.liquidity;
    }

    function trackerQuoteTokenGrowthGlobalX128(uint128 marketId, uint32 maturityTimestamp) external view returns (int256) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.trackerQuoteTokenGrowthGlobalX128;
    }

    function trackerBaseTokenGrowthGlobalX128(uint128 marketId, uint32 maturityTimestamp) external view returns (int256) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.trackerBaseTokenGrowthGlobalX128;
    }

    function ticks(uint128 marketId, uint32 maturityTimestamp, int24 _tick) external view returns (Tick.Info memory) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars._ticks[_tick];
    }

    function tickBitmap(uint128 marketId, uint32 maturityTimestamp, int16 index) external view returns (uint256) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars._tickBitmap[index];
    }

    function writeObs(uint128 marketId, uint32 maturityTimestamp) external returns (uint16, uint16) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        (vamm.vars.observationIndex, vamm.vars.observationCardinality) = vamm.vars.observations.write(
                vamm.vars.observationIndex,
                Time.blockTimestampTruncated(),
                vamm.vars.tick,
                0, // Liquidity not currently being tracked
                vamm.vars.observationCardinality,
                vamm.vars.observationCardinalityNext
            );
        return (vamm.vars.observationIndex, vamm.vars.observationCardinality);
    }
}

contract VammModuleTest is VoltzTest {

    ExtendedVammModule vammConfig;

    address constant mockRateOracle = 0xAa73aA73Aa73Aa73AA73Aa73aA73AA73aa73aa73;
    uint256 _mockLiquidityIndex = 2;
    UD60x18 mockLiquidityIndex = convert(_mockLiquidityIndex);

    // Initial VAMM state
    // Picking a price that lies on a tick boundry simplifies the math to make some tests and checks easier
    int24 initialTick = -32191;
    uint160 initSqrtPriceX96 = TickMath.getSqrtRatioAtTick(initialTick); // price = ~0.04 = ~4%
    uint128 initMarketId = 1;
    int24 initTickSpacing = 1; // TODO: test with different tick spacing; need to adapt boundTicks()
    uint32 initMaturityTimestamp = uint32(block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR));
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
        vammConfig = new ExtendedVammModule();
        vammConfig.setOwner(address(this));

        times = new uint32[](1);
        times[0] = uint32(block.timestamp);

        observedTicks = new int24[](1);
        observedTicks[0] = initialTick;

        vammConfig.createVamm(initMarketId, initSqrtPriceX96, times, observedTicks, immutableConfig, mutableConfig);
        vammConfig.increaseObservationCardinalityNext(initMarketId, initMaturityTimestamp, 3);
    }

    function test_CreateVamm() public {
        vammConfig.createVamm(2, initSqrtPriceX96, times, observedTicks, immutableConfig, mutableConfig);

        (VammConfiguration.Immutable memory config, VammConfiguration.Mutable memory _mutableConfig) = vammConfig.getVammConfig(2, initMaturityTimestamp);
        assertEq(_mutableConfig.priceImpactPhi, ud60x18(1e17));
        assertEq(_mutableConfig.priceImpactBeta, ud60x18(125e15));
        assertEq(_mutableConfig.spread, ud60x18(3e15));
        assertEq(address(_mutableConfig.rateOracle), mockRateOracle);

        assertEq(config.maturityTimestamp, initMaturityTimestamp);
        assertEq(config._maxLiquidityPerTick, type(uint128).max);
        assertEq(config._tickSpacing, 1);

        assertEq(vammConfig.sqrtPriceX96(2, initMaturityTimestamp), initSqrtPriceX96);
        assertEq(vammConfig.tick(2, initMaturityTimestamp), -32191);
        assertEq(vammConfig.observationIndex(2, initMaturityTimestamp), 0);
        assertEq(vammConfig.observationCardinality(2, initMaturityTimestamp), 1);
        assertEq(vammConfig.observationCardinalityNext(2, initMaturityTimestamp), 1);
        assertEq(vammConfig.unlocked(2, initMaturityTimestamp), true);
        assertEq(vammConfig.observations(2, initMaturityTimestamp, 0).initialized, true);
        assertEq(vammConfig.observations(2, initMaturityTimestamp, 1).initialized, false);
        assertEq(vammConfig.positionsInAccount(2, initMaturityTimestamp, 1).length, 0);
        assertEq(vammConfig.liquidity(2, initMaturityTimestamp), 0);
        assertEq(vammConfig.trackerQuoteTokenGrowthGlobalX128(2, initMaturityTimestamp), 0);
        assertEq(vammConfig.trackerBaseTokenGrowthGlobalX128(2, initMaturityTimestamp), 0);
        assertEq(vammConfig.ticks(2, initMaturityTimestamp, -32191).initialized, false);
        assertEq(vammConfig.ticks(2, initMaturityTimestamp, -32190).initialized, false);
    }

    function test_RevertWhen_CreateVamm_NotOwner() public {
        vm.prank(address(2));
        vm.expectRevert();
        vammConfig.createVamm(2, initSqrtPriceX96, times, observedTicks, immutableConfig, mutableConfig);
    }

    function test_ConfigureVamm() public {

        VammConfiguration.Mutable memory __mutableConfig = VammConfiguration.Mutable({
            priceImpactPhi: ud60x18(12e16), // 0.1
            priceImpactBeta: ud60x18(123e15), // 0.125
            spread: ud60x18(5e15), // 0.3%
            rateOracle: IRateOracle(address(23)),
            minTick: MIN_TICK,
            maxTick: MAX_TICK
        });

        vammConfig.configureVamm(initMarketId, initMaturityTimestamp, __mutableConfig);

        (VammConfiguration.Immutable memory config, VammConfiguration.Mutable memory _mutableConfig) = vammConfig.getVammConfig(initMarketId, initMaturityTimestamp);
        assertEq(_mutableConfig.priceImpactPhi, ud60x18(12e16));
        assertEq(_mutableConfig.priceImpactBeta, ud60x18(123e15));
        assertEq(_mutableConfig.spread, ud60x18(5e15));
        assertEq(address(_mutableConfig.rateOracle), address(23));
        assertEq(_mutableConfig.minTick, TickMath.DEFAULT_MIN_TICK);
        assertEq(_mutableConfig.maxTick, TickMath.DEFAULT_MAX_TICK);

        (uint160 ratioMin, uint160 ratioMax) = vammConfig.sqrtRatioMinAndMax(initMarketId, initMaturityTimestamp);
        assertEq(ratioMin, TickMath.getSqrtRatioAtTick(TickMath.DEFAULT_MIN_TICK));
        assertEq(ratioMax, TickMath.getSqrtRatioAtTick(TickMath.DEFAULT_MAX_TICK));

        // same as before
        assertEq(config.maturityTimestamp, initMaturityTimestamp);
        assertEq(config._maxLiquidityPerTick, type(uint128).max);
        assertEq(config._tickSpacing, 1);
    }

    function test_RevertWhen_ConfigureVamm_NotOwner() public {
        vm.prank(address(2));
        vm.expectRevert();
        vammConfig.configureVamm(initMarketId, initMaturityTimestamp, mutableConfig);
    }

    function test_RevertWhen_ConfigureVamm_UnknownVamm() public {
        vm.expectRevert();
        vammConfig.configureVamm(7663, initMaturityTimestamp, mutableConfig);
    }

    function test_IncreaseObservationCardinalityNext() public {
        vammConfig.increaseObservationCardinalityNext(initMarketId, initMaturityTimestamp, 256);
        assertEq(vammConfig.observationCardinalityNext(initMarketId, initMaturityTimestamp), 256);
    }

    function test_GetAdjustedDatedIRSTwap() public {
        // = (arithmeticMeanTick)*(1 + phi*(|order|^beta)) +/- spread
        vammConfig.writeObs(initMarketId, initMaturityTimestamp);

        vm.warp(block.timestamp + 60);
        UD60x18 twap = vammConfig.getAdjustedDatedIRSTwap(initMarketId, initMaturityTimestamp, 100, 30);
        assertAlmostEqual(twap, ud60x18(297476e12));
    }

    function test_GetAdjustedDatedIRSTwap_ZeroOrderSize() public {
        // = (arithmeticMeanTick  +/- spread)*(1 + phi*(|order|^beta))
        vammConfig.writeObs(initMarketId, initMaturityTimestamp);

        vm.warp(block.timestamp + 60);
        UD60x18 twap = vammConfig.getAdjustedDatedIRSTwap(initMarketId, initMaturityTimestamp, 0, 30);
        assertAlmostEqual(twap, ud60x18(250040e12));
    }

    function test_GetDatedIRSTwap() public {
        // = (arithmeticMeanTick  +/- spread)*(1 + phi*(|order|^beta))
        vammConfig.writeObs(initMarketId, initMaturityTimestamp);

        vm.warp(block.timestamp + 60);
        UD60x18 twap = vammConfig.getDatedIRSTwap(initMarketId, initMaturityTimestamp, 100, 30, true, true);
        assertAlmostEqual(twap, ud60x18(297476e12));
    }

    function test_RevertWhen_GetDatedIRSTwap_BadAdjustment() public {
        // = (arithmeticMeanTick  +/- spread)*(1 + phi*(|order|^beta))
        vammConfig.writeObs(initMarketId, initMaturityTimestamp);

        vm.warp(block.timestamp + 60);
        vm.expectRevert();
        vammConfig.getDatedIRSTwap(initMarketId, initMaturityTimestamp, 0, 30, true, true);
    }

    function test_RevertWhen_WriteTwapBeforeWindow() public {
        (uint16 indexFirst, uint16 cardFirst) = vammConfig.writeObs(initMarketId, initMaturityTimestamp);
        (uint16 indexSecond, uint16 cardSecond) = vammConfig.writeObs(initMarketId, initMaturityTimestamp);
        assertEq(indexFirst, indexSecond, "indexFirst indexSecond");
        assertEq(cardFirst, cardSecond, "card first card second");
        vm.warp(block.timestamp + 3601);
        (uint16 indexThird, uint16 cardThird) = vammConfig.writeObs(initMarketId, initMaturityTimestamp);
        assertEq(indexThird, indexSecond + 1, "index third index second");
        assertEq(cardThird, 3, "card is still 3 as set in setup");
    }
}