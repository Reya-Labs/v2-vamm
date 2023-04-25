//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

contract ProxyStorage {
    bytes32 private constant _SLOT_PROXY_STORAGE = keccak256(abi.encode("xyz.voltz.Proxy"));

    struct ProxyStore {
        address implementation;
        bool simulatingUpgrade;
    }

    function _proxyStore() internal pure returns (ProxyStore storage store) {
        bytes32 s = _SLOT_PROXY_STORAGE;
        assembly {
            store.slot := s
        }
    }
}
