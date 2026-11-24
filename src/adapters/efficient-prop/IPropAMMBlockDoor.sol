// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @title IPropAMMBlockDoor
/// @notice The entry of an Efficient PropAMM block door the adapter calls: BNB Chain's PropAMM
///         standard (BAP-710) `swap`, whose last argument is a block number.
interface IPropAMMBlockDoor {
  /// @notice Fill `amountIn` of `tokenIn`, which the caller sent to this door earlier in the same
  ///         transaction, and pay `tokenOut` to `recipient`. Reverts unless the door holds the
  ///         input, the whole input fills at `minAmountOut` or better, and `maxBlockNumber` (the
  ///         last block the swap fills in, inclusive; 0 for none) is this block or one at most the
  ///         door's `MAX_BLOCKS_AHEAD` on.
  function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 maxBlockNumber
  ) external returns (uint256 amountOut);
}
