// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice The parts of a Lunya pool the adapter and its tests use; every pool type answers them.
interface ILunyaPool {
  function token0() external view returns (address);

  function token1() external view returns (address);

  function slot0()
    external
    view
    returns (uint160 sqrtPriceX96, int24 tick, uint24 fee, uint16 feeProtocol0, uint16 feeProtocol1);

  function swap(
    address recipient,
    bool zeroForOne,
    int256 amountSpecified,
    uint160 sqrtPriceLimitX96,
    bytes calldata data
  ) external returns (int256 amount0, int256 amount1);
}
