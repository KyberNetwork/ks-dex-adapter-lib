// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IOffchainQuotedLinearFee {
  function quotes(uint32 destination, bytes32 recipient)
    external
    view
    returns (uint256 maxFee, uint256 halfAmount, uint48 issuedAt, uint48 expiry);
}
