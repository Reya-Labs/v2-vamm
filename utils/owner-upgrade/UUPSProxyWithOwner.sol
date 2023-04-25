//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./UUPSProxy.sol";
import "./OwnableStorage.sol";

contract UUPSProxyWithOwner is UUPSProxy {
    // solhint-disable-next-line no-empty-blocks
    constructor(address firstImplementation, address initialOwner) UUPSProxy(firstImplementation) {
        OwnableStorage.load().owner = initialOwner;
    }
}
