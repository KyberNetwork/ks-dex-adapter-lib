// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import './IAlgebraPool.sol';
import './IAlgebraSwapCallback.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @notice KyberSwap executor adapter for Algebra Integral concentrated-liquidity pools.
/// @dev Used by Morpheus / Robinhood Chain (and other Algebra Integral 1.x deployments).
/// Data layout matches UniswapV3Adapter: abi.encode(pool, limitSqrtPrice).
contract AlgebraIntegralAdapter is IAlgebraSwapCallback {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  /// @dev Algebra / Uniswap V3 tick-math bounds
  uint160 internal constant MIN_SQRT_RATIO = 4_295_128_739;
  uint160 internal constant MAX_SQRT_RATIO =
    1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

  function executeAlgebraIntegral(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address pool, uint160 limitSqrtPrice) = _decodeData(data);

    bool zeroToOne = tokenIn < tokenOut;
    if (limitSqrtPrice == 0) {
      limitSqrtPrice = zeroToOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    }

    (int256 amount0, int256 amount1) = IAlgebraPool(pool).swap(
      recipient, zeroToOne, int256(amountIn), limitSqrtPrice, abi.encode(tokenIn)
    );

    uint256 actualAmountIn = uint256(zeroToOne ? amount0 : amount1);
    amountUnused = amountIn - actualAmountIn;
    amountOut = uint256(zeroToOne ? -amount1 : -amount0);
  }

  function algebraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
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
    returns (address pool, uint160 limitSqrtPrice)
  {
    pool = data.decodeAddress(0);
    limitSqrtPrice = uint160(data.decodeUint256(1));
  }
}
