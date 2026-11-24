// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @notice Minimal surface of an Efficient PropAMM listing door: one listing's own venue, over the
/// listing's single pair. A door fills all of `amountIn` or reverts; it never takes part of it.
/// A listing may cap the caller's tip (`tx.gasprice` above `block.basefee`) and refuses a tip
/// above its cap. The tip does not change the price of a listing with no price source; a listing
/// bound to a source fills at what that source answers in the fill's own transaction.
interface IPropAMMListingDoor {
  /// @notice Pull entry: takes `amountIn` from the caller with `transferFrom` and pays `recipient`.
  ///         Where the listing has a pool to pay, the input goes from the caller straight to that
  ///         pool. Reverts unless the whole input fills at `minAmountOut` or better by `deadline`
  ///         (unix seconds, inclusive).
  function swapFrom(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline
  ) external returns (uint256 amountOut);
}
