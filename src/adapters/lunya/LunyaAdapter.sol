// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './ILunyaPool.sol';
import './ILunyaSwapCallback.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @notice Swaps against Lunya pools of every type: CL and CP (LunyaPoolCL) and STABLE (LunyaPoolSTABLE).
///         They share one swap and one callback, Uniswap V3's shape under Lunya's names: the pool sends
///         the output first, then calls lunyaSwapCallback for the input and checks its balance.
contract LunyaAdapter is ILunyaSwapCallback {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
  uint160 internal constant MAX_SQRT_RATIO =
    1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

  /// @param data abi.encode(pool, sqrtPriceLimitX96); a zero limit means no limit
  function executeLunya(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address pool, uint160 sqrtPriceLimitX96) = _decodeData(data);

    bool zeroForOne = tokenIn < tokenOut;
    if (sqrtPriceLimitX96 == 0) {
      sqrtPriceLimitX96 = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    }

    (int256 amount0, int256 amount1) = ILunyaPool(pool)
      .swap(recipient, zeroForOne, int256(amountIn), sqrtPriceLimitX96, abi.encode(tokenIn));

    uint256 actualAmountIn = uint256(zeroForOne ? amount0 : amount1);
    amountUnused = amountIn - actualAmountIn;
    amountOut = uint256(zeroForOne ? -amount1 : -amount0);
  }

  function lunyaSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
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
