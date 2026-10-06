// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';
import './IUSCorePool.sol';

contract USCoreAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeUSCore(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address pool = data.decodeAddress(0);
    uint256 deadline = data.decodeUint256(1);
    bytes32 refCode = data.decodeBytes32(2);
    tokenIn.forceApprove(pool, amountIn);
    amountOut = IUSCorePool(pool).swapExactIn(tokenIn, amountIn, 1, recipient, deadline, refCode);
  }
}
