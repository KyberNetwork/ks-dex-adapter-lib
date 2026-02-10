// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IUniswapV3Pool.sol';
import './IUniswapV3SwapCallback.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract UniswapV3Adapter is IUniswapV3SwapCallback {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeUniswapV3(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address pool, uint160 sqrtPriceLimitX96) = _decodeData(data);

    bool zeroForOne = tokenIn < tokenOut;
    (int256 amount0, int256 amount1) = IUniswapV3Pool(pool)
      .swap(recipient, zeroForOne, int256(amountIn), sqrtPriceLimitX96, abi.encode(tokenIn));

    uint256 actualAmountIn = uint256(zeroForOne ? amount0 : amount1);
    amountUnused = amountIn - actualAmountIn;
    amountOut = uint256(zeroForOne ? -amount1 : -amount0);
  }

  function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
    external
  {
    address tokenIn = data.decodeAddress(0);

    if (amount0Delta > 0) {
      tokenIn.safeTransfer(msg.sender, uint256(amount0Delta));
    }
    if (amount1Delta > 0) {
      tokenIn.safeTransfer(msg.sender, uint256(amount1Delta));
    }
  }

  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address pool, uint160 sqrtPriceLimitX96)
  {
    pool = data.decodeAddress(0);
    sqrtPriceLimitX96 = uint160(data.decodeUint256(1));
  }
}
