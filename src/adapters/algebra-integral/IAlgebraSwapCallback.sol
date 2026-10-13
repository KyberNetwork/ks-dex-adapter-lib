// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Callback for IAlgebraPoolActions#swap
/// @notice Any contract that calls IAlgebraPool#swap must implement this interface
interface IAlgebraSwapCallback {
  /// @notice Called to `msg.sender` after executing a swap via IAlgebraPool#swap
  /// @param amount0Delta The amount of token0 that was sent (negative) or must be received (positive)
  /// @param amount1Delta The amount of token1 that was sent (negative) or must be received (positive)
  /// @param data Any data passed through by the caller via the IAlgebraPool#swap call
  function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
    external;
}
