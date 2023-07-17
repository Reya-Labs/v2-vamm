pragma solidity >=0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import "../src/storage/LPPosition.sol";

contract ExposedLpPosition {
    using LPPosition for LPPosition.Data;

    function load(uint128 positionId) public pure returns (bytes32 s) {
        LPPosition.Data storage p = LPPosition.load(positionId);
        assembly {
            s := p.slot
        }
    } 
}

contract LPPositionTest is Test {
    ExposedLpPosition pos;

    function setUp() public virtual {
        pos = new ExposedLpPosition();
    }

    function test_LoadAtCorrectSlot() public {
        uint128 posId = LPPosition.getPositionId(1, 200, 1678777253, -360, -300);
        bytes32 slot = pos.load(posId);
        bytes32 posSlot = keccak256(abi.encode("xyz.voltz.LPPosition", posId));
        assertEq(slot, posSlot);
    }

    function testFuzz_IdCollision(
        uint128 accountId1, 
        uint128 marketId1, 
        uint32 maturityTimestamp1,
        int24 tickUpper1,
        int24 tickLower1,
        uint128 accountId2, 
        uint128 marketId2, 
        uint32 maturityTimestamp2,
        int24 tickUpper2,
        int24 tickLower2
    ) public {
        uint128 posId1 = LPPosition.getPositionId(
            accountId1, marketId1, maturityTimestamp1, tickLower1, tickUpper1
        );
        uint128 posId2 = LPPosition.getPositionId(
            accountId2, marketId2, maturityTimestamp2, tickLower2, tickUpper2
        );
        assertFalse(posId1 == posId2);
    }
}