// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ICrossCollateralRoutingFee {
  function feeContracts(uint32 destination, bytes32 targetRouter) external view returns (address);
}
