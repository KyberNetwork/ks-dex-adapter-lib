// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ILinearFee {
  function maxFee() external view returns (uint256);
  function halfAmount() external view returns (uint256);
}
