// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../src/modules/PoolModule.sol";
import "../src/modules/PoolConfigurationModule.sol";
import "./VoltzTest.sol";
import "forge-std/console2.sol";

contract ExtendedPoolConfigurationModule is PoolConfigurationModule, FeatureFlagModule {
    using SetUtil for SetUtil.AddressSet;
    using FeatureFlag for FeatureFlag.Data;

    bytes32 private constant _PAUSER_FEATURE_FLAG = "pauser";

    function setPauser(address pauser) external {
        FeatureFlag.load(_PAUSER_FEATURE_FLAG).permissionedAddresses.add(pauser);
    }

    function whenNotPaused() external view {
        PoolConfiguration.whenNotPaused();
    }

    function productAddress() external view returns (address){
        return PoolConfiguration.load().productAddress;
    }

    function positionsPerAccountLimit() external view returns (uint256){
        return PoolConfiguration.load().positionsPerAccountLimit;
    }

    function setOwner(address account) external {
        OwnableStorage.Data storage ownable = OwnableStorage.load();
        ownable.owner = account;
    }
}

contract PoolConfigurationModuleTest is VoltzTest {

    ExtendedPoolConfigurationModule poolConfig;

    function setUp() public {
        poolConfig = new ExtendedPoolConfigurationModule();
        poolConfig.setPauser(address(this));
    }

    function test_SetPauseState() public {
        poolConfig.setPauseState(true);
        vm.expectRevert();
        poolConfig.whenNotPaused();

        poolConfig.setPauseState(false);
        poolConfig.whenNotPaused();
    }

    function test_SetPauseState_NotAllowed() public {
        vm.prank(address(1));
        vm.expectRevert();
        poolConfig.setPauseState(true);
    }

    function test_SetProductAddress_NotAllowed() public {
        vm.expectRevert();
        poolConfig.setProductAddress(address(1));
    }

    function test_SetProductAddress() public {
        poolConfig.setOwner(address(this));
        poolConfig.setProductAddress(address(1));
        assertEq(poolConfig.productAddress(), address(1));
    }

    function test_SetPositionsPerAccountLimit() public {
        assertEq(poolConfig.positionsPerAccountLimit(), 0);
        poolConfig.setOwner(address(this));
        poolConfig.setPositionsPerAccountLimit(1);
        assertEq(poolConfig.positionsPerAccountLimit(), 1);
    }

    function test_RevertWhen_SetPositionsPerAccountLimit_notOwner() public {
        assertEq(poolConfig.positionsPerAccountLimit(), 0);

        vm.expectRevert(abi.encodeWithSelector(AccessError.Unauthorized.selector, address(this)));
        poolConfig.setPositionsPerAccountLimit(1);
        assertEq(poolConfig.positionsPerAccountLimit(), 0);
    }

}