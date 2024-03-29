// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../src/modules/PoolModule.sol";
import "../src/modules/PoolConfigurationModule.sol";
import "./VoltzTest.sol";
import "forge-std/console2.sol";

contract ExtendedPoolModule is PoolModule, PoolConfigurationModule {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using DatedIrsVamm for DatedIrsVamm.Data;

    function setOwner(address account) external {
        OwnableStorage.Data storage ownable = OwnableStorage.load();
        ownable.owner = account;
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

    function position(uint128 posId) external pure returns (LPPosition.Data memory){
        return LPPosition.load(posId);
    }
}

contract PoolModuleTest is VoltzTest {

    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;
    using SafeCastI256 for int256;

    ExtendedPoolModule pool;

    uint256 internal vammId;
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
        pool = new ExtendedPoolModule();
        vammId = uint256(keccak256(abi.encodePacked(initMarketId, initMaturityTimestamp)));

        times = new uint32[](1);
        times[0] = uint32(block.timestamp);

        observedTicks = new int24[](1);
        observedTicks[0] = initialTick;

        pool.createTestVamm(initMarketId, initSqrtPriceX96, times, observedTicks, immutableConfig, mutableConfig);
//        pool.increaseObservationCardinalityNext(initMarketId, initMaturityTimestamp, 16);

        pool.setOwner(address(this));
        pool.setMakerPositionsPerAccountLimit(1);
    }

    function test_Name() public {
        assertEq(pool.name(), "Dated Irs Pool");
    }

    function test_ExecuteDatedTakerOrder_NoLiquidity() public {
        vm.prank(address(0));
        (int256 executedBaseAmount, int256 executedQuoteAmount) = pool.executeDatedTakerOrder(1, initMaturityTimestamp, -100, 0);// TickMath.getSqrtRatioAtTick(MAX_TICK - 1));
        assertEq(executedBaseAmount, 0);
        assertEq(executedQuoteAmount, 0);
    }

    function test_RevertWhen_ExecuteDatedTakerOrder_NotProduct() public {
        vm.prank(address(1));
        vm.expectRevert();
        (int256 executedBaseAmount, int256 executedQuoteAmount) = pool.executeDatedTakerOrder(1, initMaturityTimestamp, -100, TickMath.getSqrtRatioAtTick(MAX_TICK - 1));
        assertEq(executedBaseAmount, 0);
        assertEq(executedQuoteAmount, 0);
    }

    function test_RevertWhen_ExecuteDatedTakerOrder_MarketNotFoud() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(CustomErrors.MarketAndMaturityCombinaitonNotSupported.selector, 3, initMaturityTimestamp));
        (int256 executedBaseAmount, int256 executedQuoteAmount) = pool.executeDatedTakerOrder(3, initMaturityTimestamp, -100, TickMath.getSqrtRatioAtTick(MAX_TICK - 1));
        assertEq(executedBaseAmount, 0);
        assertEq(executedQuoteAmount, 0);
    }

    function test_ExecuteDatedMakerOrderAndTakerOrders_Right() public {
        int256 baseAmount =  500_000_000;
        int24 tickLower = -33300;
        int24 tickUpper = -29400;
        uint128 accountId = 726;

        int128 requestedLiquidityAmount = pool.getLiquidityForBase(tickLower, tickUpper, baseAmount);
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IProductIRSModule.getCoreProxyAddress.selector),
            abi.encode(address(7))
        );
        vm.mockCall(
            address(7),
            abi.encodeWithSelector(IAccountModule.onlyAuthorized.selector, accountId, AccountRBAC._ADMIN_PERMISSION, address(this)),
            abi.encode()
        );
        
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IProductIRSModule.propagateMakerOrder.selector, accountId, initMarketId, initMaturityTimestamp, baseAmount - 1),
            abi.encode(1002, 20020, 0)
        );
        pool.initiateDatedMakerOrder(accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper, requestedLiquidityAmount);

        vm.prank(address(0));
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 executedBaseAmount,) = pool.executeDatedTakerOrder(1, initMaturityTimestamp, -100000, TickMath.getSqrtRatioAtTick(MAX_TICK - 1));
        assertEq(executedBaseAmount, -100000);
    }

    function test_ExecuteDatedMakerOrderAndTakerOrders_Left() public {
        int256 baseAmount =  500_000_000;
        int24 tickLower = -33300;
        int24 tickUpper = -29400;
        uint128 accountId = 726;

        int128 requestedLiquidityAmount = pool.getLiquidityForBase(tickLower, tickUpper, baseAmount);
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IProductIRSModule.getCoreProxyAddress.selector),
            abi.encode(address(7))
        );
        vm.mockCall(
            address(7),
            abi.encodeWithSelector(IAccountModule.onlyAuthorized.selector, accountId, AccountRBAC._ADMIN_PERMISSION, address(this)),
            abi.encode()
        );
        
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IProductIRSModule.propagateMakerOrder.selector, accountId, initMarketId, initMaturityTimestamp, baseAmount - 1),
            abi.encode(0, 0, 0)
        );
        pool.initiateDatedMakerOrder(accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper, requestedLiquidityAmount);

        vm.prank(address(0));
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        (int256 executedBaseAmount, ) = pool.executeDatedTakerOrder(initMarketId, initMaturityTimestamp, 100000, TickMath.getSqrtRatioAtTick(MIN_TICK + 1));
        assertEq(executedBaseAmount, 100000);
    }

    function test_ExecuteDatedMakerOrderAndTakerOrders_LeftRight() public {
        int256 baseAmount =  500_000_000;
        int24 tickLower = -33300;
        int24 tickUpper = -29400;
        uint128 accountId = 726;

        int128 requestedLiquidityAmount = pool.getLiquidityForBase(tickLower, tickUpper, baseAmount);
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IProductIRSModule.getCoreProxyAddress.selector),
            abi.encode(address(7))
        );
        vm.mockCall(
            address(7),
            abi.encodeWithSelector(IAccountModule.onlyAuthorized.selector, accountId, AccountRBAC._ADMIN_PERMISSION, address(this)),
            abi.encode()
        );
        
        vm.mockCall(
            address(0),
            abi.encodeWithSelector(IProductIRSModule.propagateMakerOrder.selector, accountId, initMarketId, initMaturityTimestamp, baseAmount - 1),
            abi.encode(0, 0, 0)
        );
        pool.initiateDatedMakerOrder(accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper, requestedLiquidityAmount);

        vm.startPrank(address(0));
        vm.mockCall(mockRateOracle, abi.encodeWithSelector(IRateOracle.getCurrentIndex.selector), abi.encode(mockLiquidityIndex));
        
        (int256 executedBaseAmount, int256 executedQuoteAmount) = pool.executeDatedTakerOrder(initMarketId, initMaturityTimestamp, 100000, TickMath.getSqrtRatioAtTick(MIN_TICK + 1));
        assertEq(executedBaseAmount, 100000);

        (executedBaseAmount, executedQuoteAmount) = pool.executeDatedTakerOrder(initMarketId, initMaturityTimestamp, -100000, TickMath.getSqrtRatioAtTick(MAX_TICK - 1));
        assertEq(executedBaseAmount, -100000);
    }

    function test_CloseUnfilledBase_NoPositions() public {
        vm.prank(address(0));
        int256 closeUnfilledBasePool = pool.closeUnfilledBase(initMarketId, initMaturityTimestamp, 56);
        assertEq(closeUnfilledBasePool, 0);
    }

    function test_CloseUnfilledBase_OnePosition() public {
        test_ExecuteDatedMakerOrderAndTakerOrders_Left();
        int256 baseAmount =  500_000_000;
        int24 tickLower = -33300;
        int24 tickUpper = -29400;
        uint128 accountId = 726;
        int128 requestedLiquidityAmount = pool.getLiquidityForBase(tickLower, tickUpper, baseAmount);

        vm.prank(address(0));
        int256 closeUnfilledBasePool = pool.closeUnfilledBase(initMarketId, initMaturityTimestamp, 726);
        assertEq(closeUnfilledBasePool, requestedLiquidityAmount);
        LPPosition.Data memory position = pool.position(
            LPPosition.getPositionId(accountId, initMarketId, initMaturityTimestamp, tickLower, tickUpper)
        );
        assertEq(position.liquidity, 0);
    }

    function test_SupportsInterfaceIERC165() public {
        assertTrue(pool.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterfaceIPoolModule() public {
        assertTrue(pool.supportsInterface(type(IPoolModule).interfaceId));
    }

    function test_SupportsOtherInterfaces() public {
        assertFalse(pool.supportsInterface(type(IAccountModule).interfaceId));
    }

}