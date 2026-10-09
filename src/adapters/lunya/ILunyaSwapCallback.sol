// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface ILunyaSwapCallback {
  /// @notice Called by the pool during swap, after the output has been sent; positive deltas are owed
  function lunyaSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}
