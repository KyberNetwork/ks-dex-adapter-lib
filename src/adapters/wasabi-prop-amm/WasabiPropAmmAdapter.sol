// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IPropPool.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract WasabiPropAmmAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeWasabiPropAmm(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address,
    address
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address pool = data.decodeAddress(0);

    // Approve pool to pull tokenIn from this adapter
    tokenIn.forceApprove(pool, amountIn);

    // Execute swap -- pool pulls tokenIn, sends tokenOut back to this contract
    amountOut = IPropPool(pool).swapExactInput(tokenIn, amountIn, 1);

    amountUnused = 0; // PropPool exact-input always consumes full amount
  }
}
