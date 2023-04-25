//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../utils/owner-upgrade/UUPSProxyWithOwner.sol";

/**
 * Voltz V2 VAMM Proxy Contract
 */
contract VAMMProxy is UUPSProxyWithOwner {
    // solhint-disable-next-line no-empty-blocks
    constructor(address firstImplementation, address initialOwner)
        UUPSProxyWithOwner(firstImplementation, initialOwner)
    {}
}
