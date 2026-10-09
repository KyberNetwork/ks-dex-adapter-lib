// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';
import './IBTRPool.sol';

/// @notice BTR AIMM adapter. Calls `Pool.swap_qe` directly: the BTR Router holds no swap lane, so a
///         routed swap would reach the pool from an unauthorized sender.
/// @dev data = abi.encode(pool, deadline). The pool pulls exactly `amountIn`, so the approval is
///      fully consumed and nothing is left unused.
contract BTRAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeBTR(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address pool = data.decodeAddress(0);
    uint256 deadline = data.decodeUint256(1);
    tokenIn.forceApprove(pool, amountIn);
    amountOut = IBTRPool(pool).swap_qe(tokenIn, tokenOut, amountIn, 1, recipient, deadline);
  }
}
