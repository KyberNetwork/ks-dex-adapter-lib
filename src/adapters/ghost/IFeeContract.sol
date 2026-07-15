// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IFeeContract {
  function feeType() external view returns (uint8);
}
