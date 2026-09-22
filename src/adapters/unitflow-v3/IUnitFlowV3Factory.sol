// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Canonical UnitFlow V3 factory pool registry.
interface IUnitFlowV3Factory {
  function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);
}
