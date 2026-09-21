// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '../uniswap-v3/IUniswapV3Pool.sol';
import './IUnitFlowV3SwapCallback.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title UnitFlowV3Adapter
/// @notice Executes UnitFlow V3 swaps directly against Arc mainnet pools.
/// @dev UnitFlow V3 uses the Uniswap V3 pool interface and callback settlement.
contract UnitFlowV3Adapter is IUnitFlowV3SwapCallback {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error InvalidCallbackCaller();
  error CallbackInProgress();

  address private callbackPool;

  /// @notice Executes an exact-input UnitFlow V3 swap.
  /// @param data ABI-encoded (address pool, uint160 sqrtPriceLimitX96).
  /// @param amountIn Maximum input amount, already held by this adapter.
  /// @param tokenIn Input token.
  /// @param tokenOut Output token.
  /// @param recipient Recipient of the pool's output transfer.
  /// @return amountUnused Input left unspent when the price limit causes a partial fill.
  /// @return amountOut Output amount sent by the pool.
  function executeUnitFlowV3(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address pool, uint160 sqrtPriceLimitX96) = _decodeData(data);
    if (callbackPool != address(0)) revert CallbackInProgress();

    bool zeroForOne = tokenIn < tokenOut;
    callbackPool = pool;
    (int256 amount0, int256 amount1) = IUniswapV3Pool(pool)
      .swap(recipient, zeroForOne, int256(amountIn), sqrtPriceLimitX96, abi.encode(tokenIn));
    callbackPool = address(0);

    uint256 actualAmountIn = uint256(zeroForOne ? amount0 : amount1);
    amountUnused = amountIn - actualAmountIn;
    amountOut = uint256(zeroForOne ? -amount1 : -amount0);
  }

  /// @inheritdoc IUnitFlowV3SwapCallback
  function unitFlowV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
    external
  {
    if (msg.sender != callbackPool) revert InvalidCallbackCaller();

    address tokenIn = data.decodeAddress(0);
    if (amount0Delta > 0) tokenIn.safeTransfer(msg.sender, uint256(amount0Delta));
    if (amount1Delta > 0) tokenIn.safeTransfer(msg.sender, uint256(amount1Delta));
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
