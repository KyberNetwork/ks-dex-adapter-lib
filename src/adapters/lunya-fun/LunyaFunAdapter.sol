// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './ILunyaLaunch.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @notice Buys and sells on a Lunya launch's bonding curve. Unlike the DEX pools there is no callback:
///         the launch pulls the input with transferFrom and sends the output to the recipient, so the
///         adapter approves it first.
///
///         A buy that takes the last of the curve's supply spends only what it needed and refunds the
///         rest to this adapter, which is what amountUnused reports.
contract LunyaFunAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  /// @param data abi.encode(launch)
  function executeLunyaFun(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address launch = data.decodeAddress(0);

    tokenIn.forceApprove(launch, amountIn);

    if (tokenOut == ILunyaLaunch(launch).token()) {
      amountOut = ILunyaLaunch(launch).buy(amountIn, 0, type(uint256).max, recipient);
    } else {
      amountOut = ILunyaLaunch(launch).sell(amountIn, 0, type(uint256).max, recipient);
    }

    amountUnused = tokenIn.balanceOf(address(this));
  }
}
