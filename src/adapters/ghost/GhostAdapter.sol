// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './GhostQuoter.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract GhostAdapter is GhostQuoter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeGhost(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address sourceRouter, address targetRouter) = _decodeData(data);
    bytes32 recipientBytes32 = _toBytes32(recipient);
    bytes32 targetRouterBytes32 = _toBytes32(targetRouter);
    uint32 localDomain = ICrossCollateralRouter(sourceRouter).localDomain();

    uint256 transferAmount = _calcExactInTransfer(
      sourceRouter, localDomain, targetRouterBytes32, recipientBytes32, amountIn
    );

    uint256 tokenInBefore = tokenIn.balanceOf(address(this)) - amountIn;
    uint256 tokenOutBefore = tokenOut.balanceOf(recipient);

    tokenIn.forceApprove(sourceRouter, amountIn);
    ICrossCollateralRouter(sourceRouter).transferRemoteTo{value: 0}(
      localDomain, recipientBytes32, transferAmount, targetRouterBytes32
    );

    amountOut = tokenOut.balanceOf(recipient) - tokenOutBefore;
    amountUnused = tokenIn.balanceOf(address(this)) - tokenInBefore;
  }

  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address sourceRouter, address targetRouter)
  {
    sourceRouter = data.decodeAddress(0);
    targetRouter = data.decodeAddress(1);
  }
}
