// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./interfaces/IAccountBalanceModule.sol";
import "./interfaces/IPoolModule.sol";
import "./interfaces/IPoolConfigurationModule.sol";
import "./interfaces/IVammModule.sol";
import "@voltz-protocol/util-contracts/src/interfaces/IOwnable.sol";
import "@voltz-protocol/util-modules/src/interfaces/IBaseOwnerModule.sol";
import "@voltz-protocol/util-contracts/src/interfaces/IUUPSImplementation.sol";

interface IVammProxy is 
  IOwnable,
  IBaseOwnerModule,
  IUUPSImplementation,
  IAccountBalanceModule,
  IPoolModule,
  IPoolConfigurationModule,
  IVammModule { }