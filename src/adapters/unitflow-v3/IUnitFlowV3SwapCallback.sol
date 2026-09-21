// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice Callback invoked by UnitFlow V3 pools during swap settlement.
interface IUnitFlowV3SwapCallback {
  function unitFlowV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
    external;
}
