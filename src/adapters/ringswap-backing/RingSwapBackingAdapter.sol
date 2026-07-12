// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {
  IFewBackingAwareV2Router,
  IFewBackingWrappedToken,
  IRingSwapBackingPair
} from './IFewBackingAwareV2Router.sol';

import {CalldataDecoder} from '../../libraries/CalldataDecoder.sol';
import {TokenHelper} from '../../libraries/TokenHelper.sol';

contract RingSwapBackingAdapter {
  using CalldataDecoder for bytes;
  using TokenHelper for address;

  error InvalidAmount();
  error InvalidData();
  error InvalidRecipient();
  error InvalidRouteConfig();
  error InvalidRouter();
  error InvalidTokenPair();
  error NativeTokenUnsupported();
  error OutputMismatch(uint256 reported, uint256 received);

  /// @notice Execute a Ring v2 swap directly when backing is hot, or through the recall Router.
  /// @dev `data` is abi.encode(router, useRecall). Kyber's outer router enforces route-level minOut.
  function executeRingSwapBacking(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    if (amountIn == 0) revert InvalidAmount();
    if (recipient == address(0)) revert InvalidRecipient();
    if (msg.value != 0 || tokenIn.isNative() || tokenOut.isNative()) {
      revert NativeTokenUnsupported();
    }

    if (data.length != 64) revert InvalidData();
    address routerAddress = data.decodeAddress(0);
    uint256 mode = data.decodeUint256(1);
    if (mode > 1) revert InvalidData();
    bool useRecall = mode == 1;
    if (routerAddress == address(0) || routerAddress.code.length == 0) revert InvalidRouter();
    IFewBackingAwareV2Router router = IFewBackingAwareV2Router(routerAddress);

    uint256 balanceOutBefore = tokenOut.balanceOf(recipient);
    uint256 reportedOut;
    if (useRecall) {
      reportedOut = _executeRecall(router, amountIn, tokenIn, tokenOut, recipient);
    } else {
      reportedOut = _executeHotBacking(router, amountIn, tokenIn, tokenOut, recipient);
    }

    amountOut = tokenOut.balanceOf(recipient) - balanceOutBefore;
    if (amountOut == 0 || reportedOut != amountOut) revert OutputMismatch(reportedOut, amountOut);
    amountUnused = 0;
  }

  function _executeHotBacking(
    IFewBackingAwareV2Router router,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) internal returns (uint256 amountOut) {
    (address pairAddress, address wrapper0, address wrapper1, address origin0, address origin1) =
      router.routeConfig();
    if (
      pairAddress.code.length == 0 || wrapper0.code.length == 0 || wrapper1.code.length == 0
        || wrapper0 == wrapper1
    ) revert InvalidRouteConfig();
    _validateTokenPair(tokenIn, tokenOut, origin0, origin1);

    bool zeroForOne = tokenIn == origin0;
    address wrapperIn = zeroForOne ? wrapper0 : wrapper1;
    address wrapperOut = zeroForOne ? wrapper1 : wrapper0;
    (uint112 reserve0, uint112 reserve1,) = IRingSwapBackingPair(pairAddress).getReserves();
    amountOut =
      _amountOut(amountIn, zeroForOne ? reserve0 : reserve1, zeroForOne ? reserve1 : reserve0);
    if (amountOut == 0) revert InvalidAmount();
    if (tokenOut.balanceOf(wrapperOut) < amountOut) {
      return _executeRecall(router, amountIn, tokenIn, tokenOut, recipient);
    }

    tokenIn.forceApprove(wrapperIn, amountIn);
    if (IFewBackingWrappedToken(wrapperIn).wrapTo(amountIn, pairAddress) != amountIn) {
      revert OutputMismatch(amountIn, 0);
    }
    tokenIn.forceApprove(wrapperIn, 0);
    IRingSwapBackingPair(pairAddress)
      .swap(zeroForOne ? 0 : amountOut, zeroForOne ? amountOut : 0, address(this), bytes(''));
    if (IFewBackingWrappedToken(wrapperOut).unwrapTo(amountOut, recipient) != amountOut) {
      revert OutputMismatch(amountOut, 0);
    }
  }

  function _executeRecall(
    IFewBackingAwareV2Router router,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) internal returns (uint256 amountOut) {
    _validateTokenPair(tokenIn, tokenOut, router.origin0(), router.origin1());
    address routerAddress = address(router);
    tokenIn.forceApprove(routerAddress, amountIn);
    (amountOut,) = router.swapExactInput(tokenIn, amountIn, 0, recipient, block.timestamp);
    tokenIn.forceApprove(routerAddress, 0);
  }

  function _validateTokenPair(address tokenIn, address tokenOut, address origin0, address origin1)
    internal
    pure
  {
    bool validPair =
      (tokenIn == origin0 && tokenOut == origin1) || (tokenIn == origin1 && tokenOut == origin0);
    if (!validPair) revert InvalidTokenPair();
  }

  function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
    internal
    pure
    returns (uint256)
  {
    if (reserveIn == 0 || reserveOut == 0) return 0;
    uint256 amountInWithFee = amountIn * 997;
    return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
  }
}
