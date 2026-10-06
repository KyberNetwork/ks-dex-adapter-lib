// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Minimal interface of a Mento V3 fixed-price market maker (FPMM) pool.
interface IMentoFPMM {
  function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
  function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
