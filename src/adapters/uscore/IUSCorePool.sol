// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IUSCorePool {
  function swapExactIn(
    address tokenIn,
    uint256 amountIn,
    uint256 minOut,
    address to,
    uint256 deadline,
    bytes32 refCode
  ) external returns (uint256 amountOut);
}
