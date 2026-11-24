// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import './IPropAMMBlockDoor.sol';
import './IPropAMMFront.sol';
import './IPropAMMListingDoor.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title EfficientPropAdapter
/// @notice KyberSwap DEX adapter for Efficient PropAMM listings (`efficient-prop`): exact-input
///         fills of one listing, either direction of its pair, through the listing's own door or
///         through the front it trades on, as the pool's data says.
/// @dev Every route fills the whole input or reverts, so nothing is left unused, and pays
///      `recipient` directly. The venue-level minimum output is 1 and the deadline is this block;
///      KyberSwap's routing layer enforces minReturn. No route catches a venue's revert. The data
///      is the companion source's own: its words are decoded as they are, and only the mode is
///      checked.
///      - Mode 0, the door: the adapter approves the door for exactly `amountIn` and calls its pull
///        entry, `swapFrom`, which takes exactly that amount, so the approval ends at zero.
///      - Mode 1, the front: where the front names a pool to pay for the listing (`payPoolOf`),
///        the adapter transfers the input to that pool and calls the paid entry,
///        `swapExactInPaid`, in the same frame with no call between, so a refusal reverts the
///        transfer with it. Otherwise it approves the front for exactly `amountIn` and calls the
///        named entry, `swapSender`, which pulls exactly that amount.
///      - Mode 2, a block door (BNB Chain's PropAMM standard, BAP-710; not live: no source builds
///        this mode's data yet): the data's first word is the block door, a push-payment venue
///        whose `swap` reads its last argument as a block number. The adapter transfers the input
///        to that door and calls `swap` in the same frame with no call between, naming this block
///        as the last block, so a refusal reverts the transfer with it and nothing pushed is left
///        for another caller. No approval is given.
///      - Mode 3 is left unused, for a later mode that fills a signed firm quote. This adapter
///        refuses it, as any mode past 2 (`UnknownFillMode`).
contract EfficientPropAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  /// @notice The pool's data names a fill mode other than 0 (the door), 1 (the front) and 2 (a
  ///         block door): 3, left unused for a firm mode, or any above it.
  error UnknownFillMode(uint256 mode);

  uint256 internal constant MODE_DOOR = 0;
  uint256 internal constant MODE_FRONT = 1;
  uint256 internal constant MODE_BLOCK_DOOR = 2;

  /// @notice Execute an exact-input fill against an Efficient PropAMM listing.
  /// @param data ABI-encoded (address door, address front, uint24 listing, uint8 mode): the
  ///        listing's door, the front it trades on, its id there, and the fill mode, 0 through the
  ///        door or 1 through the front
  /// @param amountIn Amount of tokenIn (already in this contract)
  /// @param tokenIn Input token address, either token of the listing's pair
  /// @param tokenOut Output token address, the other token of the pair
  /// @param recipient Recipient of the output
  /// @return amountUnused Always zero; every route fills the whole input or reverts
  /// @return amountOut Amount of tokenOut paid to the recipient
  function executeEfficientProp(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    uint256 mode = data.decodeUint256(3);

    if (mode == MODE_DOOR) {
      address door = data.decodeAddress(0);
      tokenIn.forceApprove(door, amountIn);
      amountOut = IPropAMMListingDoor(door)
        .swapFrom(tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp);
    } else if (mode == MODE_FRONT) {
      IPropAMMFront front = IPropAMMFront(data.decodeAddress(1));
      uint24 listing = uint24(data.decodeUint256(2));
      address pool = front.payPoolOf(listing);
      if (pool != address(0)) {
        // the payment and the paid call in one frame, with no call between
        tokenIn.safeTransfer(pool, amountIn);
        amountOut = front.swapExactInPaid(
          tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp, listing
        );
      } else {
        tokenIn.forceApprove(address(front), amountIn);
        amountOut =
          front.swapSender(tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp, listing);
      }
    } else if (mode == MODE_BLOCK_DOOR) {
      address blockDoor = data.decodeAddress(0);
      tokenIn.safeTransfer(blockDoor, amountIn);
      amountOut =
        IPropAMMBlockDoor(blockDoor).swap(tokenIn, tokenOut, amountIn, 1, recipient, block.number);
    } else {
      revert UnknownFillMode(mode);
    }
    amountUnused = 0; // every route fills the whole input or reverts
  }
}
