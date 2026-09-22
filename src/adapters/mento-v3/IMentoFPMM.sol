// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @notice Minimal interface of a Mento V3 fixed-price market maker (FPMM) pool.
interface IMentoFPMM {
  function token0() external view returns (address);
  function token1() external view returns (address);
  function getReserves()
    external
    view
    returns (uint256 reserve0, uint256 reserve1, uint256 blockTimestampLast);
  function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);
  function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
