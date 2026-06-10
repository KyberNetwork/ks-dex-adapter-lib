// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

struct Quote {
  address token;
  uint256 amount;
}

interface ICrossCollateralRouter {
  function transferRemoteTo(
    uint32 _destination,
    bytes32 _recipient,
    uint256 _amount,
    bytes32 _targetRouter
  ) external payable returns (bytes32 messageId);

  function quoteTransferRemoteTo(
    uint32 _destination,
    bytes32 _recipient,
    uint256 _amount,
    bytes32 _targetRouter
  ) external view returns (Quote[] memory quotes);

  function localDomain() external view returns (uint32);
}
