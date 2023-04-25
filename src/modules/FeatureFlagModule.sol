//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {FeatureFlagModule as BaseFeatureFlagModule} from "../../utils/feature-flag/FeatureFlagModule.sol";

/**
 * @title Module that allows disabling certain system features.
 *
 * Users will not be able to interact with certain functions associated to disabled features.
 */
// solhint-disable-next-line no-empty-blocks
contract FeatureFlagModule is BaseFeatureFlagModule {
  uint a = 1;
}