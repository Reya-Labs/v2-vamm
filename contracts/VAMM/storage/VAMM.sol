// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/AccessError.sol";
import "../interfaces/IVAMM.sol";

/**
 * @title Connects external contracts that implement the `IVAMM` interface to the protocol.
 *
 */
library VAMM {
    /**
     * @dev Thrown when a specified vamm is not found.
     */
    error VAMMNotFound(uint128 vammId);

    struct Data {
        /**
         * @dev Numeric identifier for the vamm. Must be unique.
         * @dev There cannot be a vamm with id zero (See VAMMCreator.create()). Id zero is used as a null vamm reference.
         */
        uint128 id;
        /**
         * @dev Address for the external contract that implements the `IVAMM` interface, which this VAMM objects connects to.
         *
         * Note: This object is how the system tracks the vamm. The actual vamm is external to the system, i.e. its own contract.
         */
        address vammAddress;
        /**
         * @dev Text identifier for the vamm.
         *
         * Not required to be unique.
         */
        string name;
        /**
         * @dev Creator of the vamm, which has configuration access rights for the vamm.
         *
         * See onlyVAMMOwner.
         */
        address owner;

        address gtwapOracle;
        uint256 termEndTimestampWad;
        uint128 _maxLiquidityPerTick;
        bool _unlocked; // Mutex
        uint128 _accumulator;
        uint256 _protocolFees;
        int256 _fixedTokenGrowthGlobalX128;
        int256 _variableTokenGrowthGlobalX128;
        int24 _tickSpacing;
        mapping(int24 => Tick.Info) _ticks;
        mapping(int16 => uint256) _tickBitmap;
        IVAMM.VAMMVars _vammVars;
        mapping(address => bool) pauser;
        bool paused;
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id.
     */
    function load(uint128 id) internal pure returns (Data storage vamm) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.VAMM", id));
        assembly {
            vamm.slot := s
        }
    }

    /**
     * @dev Reverts if the caller is not the owner of the specified vamm
     */
    function onlyVAMMOwner(uint128 vammId, address caller) internal view {
        if (VAMM.load(vammId).owner != caller) {
            revert AccessError.Unauthorized(caller);
        }
    }

    /**
     * @dev 
     */
    function mint(Data storage self, int24 tickLower, int24 tickUpper, uint256 baseAmount)
        internal
    {
        return IVAMM(self.vammAddress).mint(tickLower, tickUpper, base);
    }

    /**
     * @dev 
    */
    function swap(Data storage self, uint256 baseAmount, int24 tickLimit)
        internal
        returns (int256 fixedTokenDelta, int256 variableTokenDelta)
    {
        return IVAMM(self.vammAddress).swap(base, tickLimit);
    }
}
