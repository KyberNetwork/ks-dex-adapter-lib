// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IPropPool {

  /// @notice Swap exact input amount of tokenIn for tokenOut
  /// @param tokenIn The token to swap from
  /// @param amountIn The amount of tokenIn to swap
  /// @param minAmountOut The minimum amount of tokenOut to receive
  /// @return amountOut The amount of tokenOut received
  function swapExactInput(
    address tokenIn,
    uint256 amountIn,
    uint256 minAmountOut
  ) external returns (uint256 amountOut);

  /// @notice Get the base token of the pool
  /// @return The base token
  function getBaseToken() external view returns (address);

  /// @notice Get the quote token of the pool
  /// @return The quote token
  function getQuoteToken() external view returns (address);
}
