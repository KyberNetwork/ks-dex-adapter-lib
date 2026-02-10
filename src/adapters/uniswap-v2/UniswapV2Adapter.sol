// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IUniswapV2Pair.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract UniswapV2Adapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeUniswapV2(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address pool, uint256 fee, uint256 feeDenom) = _decodeData(data);

    tokenIn.safeTransfer(pool, amountIn);

    bool zeroForOne = tokenIn < tokenOut;
    (uint256 reserveIn, uint256 reserveOut,) = IUniswapV2Pair(pool).getReserves();
    if (!zeroForOne) {
      (reserveIn, reserveOut) = (reserveOut, reserveIn);
    }

    // adjust amountIn in case of fee-on-transfer tokens or rebasing tokens
    amountIn = tokenIn.balanceOf(pool) - reserveIn;
    amountOut = _getAmountOut(amountIn, reserveIn, reserveOut, fee, feeDenom);

    // record tokenOut balance before the swap
    uint256 balanceOutBefore = tokenOut.balanceOf(recipient);

    if (zeroForOne) {
      IUniswapV2Pair(pool).swap(0, amountOut, recipient, '');
    } else {
      IUniswapV2Pair(pool).swap(amountOut, 0, recipient, '');
    }

    amountUnused = 0;
    // adjust amountOut in case of fee-on-transfer tokens or rebasing tokens
    amountOut = tokenOut.balanceOf(recipient) - balanceOutBefore;
  }

  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address pool, uint256 fee, uint256 feeDenom)
  {
    pool = data.decodeAddress(0);
    fee = data.decodeUint256(1);
    feeDenom = data.decodeUint256(2);
  }

  function _getAmountOut(
    uint256 amountIn,
    uint256 reserveIn,
    uint256 reserveOut,
    uint256 fee,
    uint256 feeDenom
  ) internal pure returns (uint256 amountOut) {
    uint256 amountInWithFee = amountIn * (feeDenom - fee);
    uint256 numerator = amountInWithFee * reserveOut;
    uint256 denominator = reserveIn * feeDenom + amountInWithFee;
    amountOut = numerator / denominator;
  }
}
