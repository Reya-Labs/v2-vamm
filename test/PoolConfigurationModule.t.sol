// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../src/modules/PoolModule.sol";
import "../src/modules/PoolConfigurationModule.sol";
import "./VoltzTest.sol";
import "forge-std/console2.sol";

contract ExtendedPoolConfigurationModule is PoolConfigurationModule, FeatureFlagModule {
    using SetUtil for SetUtil.AddressSet;
    using FeatureFlag for FeatureFlag.Data;

    bytes32 private constant _PAUSER_FEATURE_FLAG = "registerProduct";

    function setPauser(address pauser) external {
        FeatureFlag.load(_PAUSER_FEATURE_FLAG).permissionedAddresses.add(pauser);
    }

    function whenNotPaused() external {
        PoolConfiguration.whenNotPaused();
    }

    function productAddress() external returns (address){
        return PoolConfiguration.load().productAddress;
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

}