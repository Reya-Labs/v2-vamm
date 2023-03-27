// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @title Interface a Pool needs to adhere.
interface IVAMM {
    /// @notice returns a human-readable name for a given vamm
    function name(uint128 vammId) external view returns (string memory);

    function mint(int24 tickLower, int24 tickUpper, uint256 baseAmount)
        external;

    function swap(uint256 baseAmount, int24 tickLimit)
        external
        view
        returns (int256 fixedTokenDelta, int256 variableTokenDelta);

    /// @dev emitted after a successful minting of a given LP position
    event Mint(
        address sender,
        uint128 indexed accountId,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int128 baseAmount
    );

}
