// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './ICrossCollateralRouter.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract GhostAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeGhost(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address sourceRouter, bytes32 targetRouter, uint256 amount) = _decodeData(data);
    uint32 destination = ICrossCollateralRouter(sourceRouter).localDomain();
    bytes32 recipientBytes32 = bytes32(uint256(uint160(recipient)));

    uint256 tokenInBefore = tokenIn.balanceOf(address(this)) - amountIn;
    uint256 tokenOutBefore = tokenOut.balanceOf(recipient);

    tokenIn.forceApprove(sourceRouter, amountIn);
    ICrossCollateralRouter(sourceRouter).transferRemoteTo{value: 0}(
      destination, recipientBytes32, amount, targetRouter
    );

    amountOut = tokenOut.balanceOf(recipient) - tokenOutBefore;
    amountUnused = tokenIn.balanceOf(address(this)) - tokenInBefore;
  }

  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address sourceRouter, bytes32 targetRouter, uint256 amount)
  {
    sourceRouter = data.decodeAddress(0);
    targetRouter = data.decodeBytes32(1);
    amount = data.decodeUint256(2);
  }
}
