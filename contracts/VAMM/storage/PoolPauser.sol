// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @title Interface a Pool needs to adhere.
library PoolPauser {

    event PauseState(bool newPauseState);

    struct Data {
        bool paused;
    }

    function load() internal pure returns (Data storage self) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.PoolPausers"));
        assembly {
            self.slot := s
        }
    }

    function setPauseState(Data storage self, bool state) external {
        self.paused = state;
        emit PauseState(state);
    }

    function whenNotPaused(Data storage self) external view {
        require(!self.paused, "Paused");
    }
}
