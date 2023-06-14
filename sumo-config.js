module.exports = {
  buildDir: "out",
  contractsDir: "src",
  testDir: "test",
  skipContracts: [
    "VammProxy.sol",
    "interfaces",
    "modules/FeatureFlagModule.sol",
    "modules/OwnerUpgradeModule.sol",
  ],
  skipTests: [],
  testingTimeOutInSec: 300,
  network: "none",
  testingFramework: "forge",
  optimized: true,
  tce: true,
};
