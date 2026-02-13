// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IPropPool {
  function swapExactInput(
    address tokenIn,
    uint256 amountIn,
    uint256 minAmountOut
  ) external returns (uint256 amountOut);

  function getBaseToken() external view returns (address);
  function getQuoteToken() external view returns (address);
}
