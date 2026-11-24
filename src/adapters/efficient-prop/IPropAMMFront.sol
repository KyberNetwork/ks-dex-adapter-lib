// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @notice Minimal surface of an Efficient PropAMM front: the venue every listing on a chain fills
/// through, each fill naming its listing. A named fill fills all of `amountIn` or reverts.
interface IPropAMMFront {
  /// @notice The pool the paid entry takes `listing`'s input at: the listing's pool where the
  ///         listing has no credit mode, zero for any other listing, which fills through
  ///         `swapSender`.
  function payPoolOf(uint24 listing) external view returns (address pool);

  /// @notice The allowance entry: pulls `amountIn` from the caller straight into the pool of
  ///         `listing` and pays `recipient`. Reverts unless the whole input fills at
  ///         `minAmountOut` or better by `deadline` (unix seconds, inclusive).
  function swapSender(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline,
    uint24 listing
  ) external returns (uint256 amountOut);

  /// @notice The paid entry: `swapSender` with `amountIn` already sent to `payPoolOf(listing)`
  ///         earlier in the same transaction, which the pool's own input check proves. A payer
  ///         sends and calls with no call between. Refuses a listing with a credit mode.
  function swapExactInPaid(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline,
    uint24 listing
  ) external returns (uint256 amountOut);
}
