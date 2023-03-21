pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "../contracts/VAMM/storage/DatedIrsVAMM.sol";


// contract ExposedDatedIrsVamm is CoreState {
contract ExposedDatedIrsVamm {
    using DatedIrsVamm for DatedIrsVamm.Data;
    DatedIrsVamm.Data public vamm;


    function initialize(uint160 sqrtPriceX96, uint256 _termEndTimestamp, uint128 _marketId, int24 _tickSpacing, DatedIrsVamm.DatedIrsVAMMConfig memory _config) internal {
        vamm.initialize(sqrtPriceX96, _termEndTimestamp, _marketId, _tickSpacing,  _config);
        // emit Initialize(sqrtPriceX96, tick); // TODO: emit log for new VAMM, either here or in DatedIrsVAMMPool
    }

    // Exposed functions
    // function load(uint128 id) external {
    //     vamm = DatedIrsVamm.load(id);
    // }

    // function create(uint128 _marketId, uint256 _maturityTimestamp,  uint160 _sqrtPriceX96, int24 _tickSpacing, DatedIrsVamm.DatedIrsVAMMConfig memory _config) external returns (bytes32 s) {
    //     DatedIrsVamm.Data storage account = Account.create(id, owner);
    //     assembly {
    //         s := account.slot
    //     }
    // }

    function propagatePosition(uint256 positionId) external {
        vamm.propagatePosition(positionId);
    }

    function executeDatedMakerOrder(uint128 accountId,
        uint160 fixedRateLower,
        uint160 fixedRateUpper,
        int128 requestedBaseAmount) external returns (int256 executedBaseAmount) {
        return vamm.executeDatedMakerOrder(accountId,
        fixedRateLower,
        fixedRateUpper,
        requestedBaseAmount);
    }
}

contract VammTest is Test {
    uint256 testNumber;
    ExposedDatedIrsVamm internal vamm;
    uint256 constant testPositionId = 1;

    function setUp() public {
        vamm = new ExposedDatedIrsVamm();
        testNumber = 42;
    }

    function test_NumberIs42() public {
        assertEq(testNumber, 42);
    }

    function testFail_Subtract43() public {
        testNumber -= 43;
    }

    function testFail_GetUnopenedPosition() public {
        vamm.getRawPosition(testPositionId);
    }

    function test_OpenPosition() public {
        uint256 openedPosition = vamm.openPosition(1,1,3);

        assertEq(openedPosition, 1);
    }
}