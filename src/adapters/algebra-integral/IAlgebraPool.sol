// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAlgebraPool {
  function token0() external view returns (address);
  function token1() external view returns (address);

  function globalState()
    external
    view
    returns (
      uint160 price,
      int24 tick,
      uint16 lastFee,
      uint8 pluginConfig,
      uint16 communityFee,
      bool unlocked
    );

  /// @notice Swap token0 for token1, or token1 for token0
  /// @dev The caller of this method receives a callback in the form of
  /// IAlgebraSwapCallback#algebraSwapCallback
  function swap(
    address recipient,
    bool zeroToOne,
    int256 amountRequired,
    uint160 limitSqrtPrice,
    bytes calldata data
  ) external returns (int256 amount0, int256 amount1);
}
