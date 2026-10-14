// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFlywheelNativeSettlement {
  function buy(
    address token,
    uint256 minQuote,
    uint256 minTokens,
    uint256 deadline,
    bytes calldata route
  ) external payable returns (uint256);
  function buyWithRefund(
    address token,
    uint256 minQuote,
    uint256 minTokens,
    uint256 deadline,
    bytes calldata route,
    uint256 minRefundETH,
    bytes calldata refundRoute
  ) external payable returns (uint256);
  function sell(
    address token,
    uint256 amount,
    uint256 minQuote,
    uint256 minETH,
    uint256 deadline,
    bytes calldata route
  ) external returns (uint256);
}

interface IFlywheelNativeToken {
  function factory() external view returns (address);
}

interface IFlywheelWETH {
  function deposit() external payable;
  function withdraw(uint256 amount) external;
}
