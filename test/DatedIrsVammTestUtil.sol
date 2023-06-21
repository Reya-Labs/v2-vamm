pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "./VoltzTest.sol";
import "../src/storage/LPPosition.sol";
import "../src/storage/DatedIrsVAMM.sol";
import "../utils/CustomErrors.sol";
import "../utils/vamm-math/Tick.sol";

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, convert, ud60x18, uMAX_UD60x18, uUNIT } from "@prb/math/UD60x18.sol";
import { SD59x18, sd59x18, convert } from "@prb/math/SD59x18.sol";

/// @dev Contains assertions and other functions used by multiple tests
contract DatedIrsVammTestUtil is VoltzTest {
    // Contracts under test
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    uint256 internal vammId;
    address constant mockRateOracle = 0xAa73aA73Aa73Aa73AA73Aa73aA73AA73aa73aa73;

    // Initial VAMM state
    // Picking a price that lies on a tick boundry simplifies the math to make some tests and checks easier
    uint160 initSqrtPriceX96 = TickMath.getSqrtRatioAtTick(-32191); // price = ~0.04 = ~4%
    uint128 initMarketId = 1;
    int24 initTickSpacing = 1; // TODO: test with different tick spacing; need to adapt boundTicks()
    uint32 initMaturityTimestamp = uint32(block.timestamp + convert(FixedAndVariableMath.SECONDS_IN_YEAR));
    VammConfiguration.Mutable internal mutableConfig = VammConfiguration.Mutable({
        priceImpactPhi: ud60x18(1e17), // 0.1
        priceImpactBeta: ud60x18(125e15), // 0.125
        spread: ud60x18(3e15), // 0.3%
        rateOracle: IRateOracle(mockRateOracle)
    });

    VammConfiguration.Immutable internal immutableConfig = VammConfiguration.Immutable({
        maturityTimestamp: initMaturityTimestamp,
        _maxLiquidityPerTick: type(uint128).max,
        _tickSpacing: initTickSpacing,
        marketId: initMarketId
    });

    /// @notice Computes the amount of liquidity per tick to use for a given base amount and price range
    /// @dev Calculates `baseAmount / (sqrtRatio(tickUpper) - sqrtRatio(tickLower))`.
    /// @param tickLower The first tick boundary
    /// @param tickUpper The second tick boundary
    /// @param baseAmount The amount of base token being sent in
    /// @return liquidity The amount of liquidity per tick
    function getLiquidityForBase(
        int24 tickLower,
        int24 tickUpper,
        int256 baseAmount
    ) public view returns (int128 liquidity) {

        // get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        uint256 absLiquidity = FullMath
                .mulDiv(uint256(baseAmount > 0 ? baseAmount : -baseAmount), VAMMBase.Q96, sqrtRatioBX96 - sqrtRatioAX96);

        return baseAmount > 0 ? absLiquidity.toInt().to128() : -(absLiquidity.toInt().to128());
    }

    function tickDistanceFromCurrentToTick(ExposedDatedIrsVamm vamm, int24 _tick) public view returns (uint256 absoluteDistance) {
        int24 currentTick = vamm.tick();
        return tickDistance(currentTick, _tick);
    }

    function boundNewPositionLiquidityAmount(
        ExposedDatedIrsVamm vamm,
        int24 tickLower,
        int24 tickUpper,
        int128 unboundLiquidityDelta)
    internal view returns (int128 liquidityDelta)
    {
        // Ticks must be in range and cannot be equal
        // uint256 tickRange = tickDistance(_tickLower, _tickUpper);
        uint128 maxLiquidityPerTick = vamm.maxLiquidityPerTick();
        //int256 max = min(int256(type(int128).max), int256(uint256(maxLiquidityPerTick)*tickRange));
        int256 max = min(int256(type(int128).max - 1), int256(uint256(maxLiquidityPerTick))); // TODO: why is type(int128).max not safe?

        // Amounts of liquidty smaller than required for base amount of 100k might produce acceptable rounding errors that nonetheless make tests fiddly
        int256 min = getLiquidityForBase(tickLower, tickUpper, 1000_000); 

        return int128(bound(unboundLiquidityDelta, min, max)); // New positions cannot withdraw liquidity so >= 0
    }

    function boundNewPositionLiquidityAmount(
        uint128 maxLiquidityPerTick,
        int24 tickLower,
        int24 tickUpper,
        int128 unboundLiquidityDelta)
    internal view returns (int128 liquidityDelta)
    {
        //int256 max = min(int256(type(int128).max), int256(uint256(maxLiquidityPerTick)*tickRange));
        int256 max = min(int256(type(int128).max - 1), int256(uint256(maxLiquidityPerTick))); // TODO: why is type(int128).max not safe?

        // Amounts of liquidty smaller than required for base amount of 100k might produce acceptable rounding errors that nonetheless make tests fiddly
        int256 min = getLiquidityForBase(tickLower, tickUpper, 1000_000); 

        return int128(bound(unboundLiquidityDelta, min, max)); // New positions cannot withdraw liquidity so >= 0
    }

    function logTickInfo(string memory label, int24 _tick) view internal {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        console2.log(label);
        console2.log("- tickNumber", int256(_tick));
        Tick.Info storage t = vamm.vars._ticks[_tick];
        console2.log("- liquidityGross", uint256(t.liquidityGross));
        console2.log("- liquidityNet", int256(t.liquidityNet));
        console2.log("- trackerQuoteTokenGrowthOutsideX128", t.trackerQuoteTokenGrowthOutsideX128);
        console2.log("- trackerBaseTokenGrowthOutsideX128", t.trackerBaseTokenGrowthOutsideX128);
        console2.log("- initialized", t.initialized);
    }
}

contract ExposedDatedIrsVamm {

    using DatedIrsVamm for DatedIrsVamm.Data;

    uint256 vammId;

    constructor(uint256 _vammId) {
        vammId = _vammId;
    }

    function create(
        uint128 _marketId,
        uint160 _sqrtPriceX96,
        VammConfiguration.Immutable memory _config,
        VammConfiguration.Mutable memory _mutableConfig
    ) external returns (bytes32 s){
        DatedIrsVamm.Data storage vamm =  DatedIrsVamm.create(
            _marketId,
            _sqrtPriceX96,
            _config,
            _mutableConfig
        );

        assembly {
            s := vamm.slot
        }
    }

    function load(
    ) public returns (bytes32 s) {
        DatedIrsVamm.Data storage vamm =  DatedIrsVamm.load(vammId);
        assembly {
            s := vamm.slot
        }
    }

    function initialize(uint160 _sqrtPriceX96) public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        vamm.initialize(_sqrtPriceX96);
    }

    function twap(uint32 secondsAgo, int256 orderSize, bool adjustForPriceImpact,  bool adjustForSpread) 
        public
        returns (UD60x18 geometricMeanPrice) 
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        return vamm.twap( secondsAgo, orderSize, adjustForPriceImpact, adjustForSpread);
    }

    function observe(uint32 secondsAgo) public returns (int24) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        return vamm.observe(secondsAgo);
    }

    function observe( uint32[] memory secondsAgo) public returns (int56[] memory, uint160[] memory) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        return vamm.observe(secondsAgo);
    }

     function increaseObservationCardinalityNext( uint16 _observationCardinalityNext) public{
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        return vamm.increaseObservationCardinalityNext(_observationCardinalityNext);
    }

    function executeDatedMakerOrder(
        
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        vamm.executeDatedMakerOrder(accountId, tickLower, tickUpper, liquidityDelta);
    }

    function configure(VammConfiguration.Mutable memory _config) public {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        vamm.configure(_config);
    }

    function getAccountFilledBalances(uint128 accountId) public returns (int256, int256) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        return vamm.getAccountFilledBalances(accountId);
    }

    function getAccountUnfilledBases(uint128 accountId) public returns (uint256, uint256) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        return vamm.getAccountUnfilledBases(accountId);
    }

    function vammSwap(VAMMBase.SwapParams memory params) public returns (int256, int256) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        return vamm.vammSwap(params);
    }

    function computeGrowthInside(int24 tickLower, int24 tickUpper) public view returns (int256, int256) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        return vamm.computeGrowthInside(tickLower, tickUpper);
    }

    function updatePositionTokenBalances(
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        bool isMintBurn
    ) public returns (LPPosition.Data memory) {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.load(vammId);
        LPPosition.Data storage _position = LPPosition.load(LPPosition.getPositionId(accountId, tickLower, tickUpper));
        if (_position.accountId == 0) {
            _position = LPPosition.create(accountId, tickLower, tickUpper);
        }
        vamm.updatePositionTokenBalances(_position, tickLower, tickUpper, isMintBurn);

        return _position;
    }

    ///// GETTERS

    function tick() external view returns (int24){
        return DatedIrsVamm.load(vammId).vars.tick;
    }

    function liquidity() external view returns (uint128){
        return DatedIrsVamm.load(vammId).vars.liquidity;
    }

    function ticks(int24 _tick) external view returns (Tick.Info memory){
        return DatedIrsVamm.load(vammId).vars._ticks[_tick];
    }

    function sqrtPriceX96() external view returns (uint160){
        return DatedIrsVamm.load(vammId).vars.sqrtPriceX96;
    }

    function observationCardinality() external view returns (uint16){
        return DatedIrsVamm.load(vammId).vars.observationCardinality;
    }

    function observationIndex() external view returns (uint16){
        return DatedIrsVamm.load(vammId).vars.observationIndex;
    }

    function observationCardinalityNext() external view returns (uint16){
        return DatedIrsVamm.load(vammId).vars.observationCardinalityNext;
    }

    function unlocked() external view returns (bool){
        return DatedIrsVamm.load(vammId).vars.unlocked;
    }

    function priceImpactPhi() external view returns (UD60x18){
        return DatedIrsVamm.load(vammId).mutableConfig.priceImpactPhi;
    }

    function priceImpactBeta() external view returns (UD60x18){
        return DatedIrsVamm.load(vammId).mutableConfig.priceImpactBeta;
    }

    function spread() external view returns (UD60x18){
        return DatedIrsVamm.load(vammId).mutableConfig.spread;
    }

    function rateOracle() external view returns (IRateOracle){
        return DatedIrsVamm.load(vammId).mutableConfig.rateOracle;
    }

    function maxLiquidityPerTick() external view returns (uint128){
        return DatedIrsVamm.load(vammId).immutableConfig._maxLiquidityPerTick;
    }

    function trackerBaseTokenGrowthGlobalX128() external view returns (int256){
        return DatedIrsVamm.load(vammId).vars.trackerBaseTokenGrowthGlobalX128;
    }

    function trackerQuoteTokenGrowthGlobalX128() external view returns (int256){
        return DatedIrsVamm.load(vammId).vars.trackerQuoteTokenGrowthGlobalX128;
    }

    function position(uint128 posId) external view returns (LPPosition.Data memory){
        return LPPosition.load(posId);
    }

}