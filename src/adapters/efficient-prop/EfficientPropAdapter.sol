// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import './IPropAMMFront.sol';
import './IPropAMMListingDoor.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title EfficientPropAdapter
/// @notice KyberSwap DEX adapter for Efficient PropAMM listings (`efficient-prop`): exact-input
///         fills of one listing, either direction of its pair.
/// @dev `mode` picks the entry: 0 fills through the listing's own door, any other value through
///      the front the listing trades on. The front names the pool to pay for a listing
///      (`payPoolOf`); where it names none, the listing fills through the front's allowance entry.
///      Every entry fills the whole input or reverts and pays `recipient` directly. The
///      venue-level minimum output is 1; KyberSwap's routing layer enforces minReturn.
contract EfficientPropAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  /// @notice Execute an exact-input fill against an Efficient PropAMM listing.
  /// @param data ABI-encoded: (address door, address front, uint24 listing, uint256 mode) — 0 =
  ///        the door, 1 = the front
  /// @param amountIn Amount of tokenIn (already in this contract)
  /// @param tokenIn Input token address
  /// @param tokenOut Output token address
  /// @param recipient Recipient of the output
  /// @return amountUnused Always zero: a fill takes the whole input or reverts
  /// @return amountOut Amount of tokenOut paid to the recipient
  function executeEfficientProp(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    uint256 mode = data.decodeUint256(3); // 0 = the door, 1 = the front

    if (mode == 0) {
      address door = data.decodeAddress(0);
      tokenIn.forceApprove(door, amountIn);
      amountOut = IPropAMMListingDoor(door)
        .swapFrom(tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp);
    } else {
      IPropAMMFront front = IPropAMMFront(data.decodeAddress(1));
      uint24 listing = uint24(data.decodeUint256(2));
      address pool = front.payPoolOf(listing);
      if (pool != address(0)) {
        tokenIn.safeTransfer(pool, amountIn);
        amountOut = front.swapExactInPaid(
          tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp, listing
        );
      } else {
        tokenIn.forceApprove(address(front), amountIn);
        amountOut =
          front.swapSender(tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp, listing);
      }
    }
  }
}
