// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Public execution surface of the Spire MM platform.
interface ISpireEntrypoint {
  /// @notice Consumes the live curve, pulls all input and pays the recipient from available custody.
  /// @param base The pair's base asset.
  /// @param tokenIn Either the base or quote asset.
  /// @param amountIn Exact ERC20 input amount.
  /// @param minAmountOut Minimum acceptable output.
  /// @param recipient Address receiving the output.
  /// @return amountOut Actual output amount.
  function swapExactAmountIn(
    address base,
    address tokenIn,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient
  ) external returns (uint256 amountOut);
}
