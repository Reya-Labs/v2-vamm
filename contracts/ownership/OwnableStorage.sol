//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11 <0.9.0;

import "../utils/CustomErrors.sol";

library OwnableStorage {
    bytes32 private constant _SLOT_OWNABLE_STORAGE =
        keccak256(abi.encode("xyz.voltz.v2-periphery.Ownable"));

    struct Data {
        address owner;
        address nominatedOwner;
    }

    function load() internal pure returns (Data storage store) {
        bytes32 s = _SLOT_OWNABLE_STORAGE;
        assembly {
            store.slot := s
        }
    }

    function onlyOwner() internal view {
        if (msg.sender != getOwner()) {
            revert CustomErrors.Unauthorized(msg.sender);
        }
    }

    function getOwner() internal view returns (address) {
        return OwnableStorage.load().owner;
    }
}