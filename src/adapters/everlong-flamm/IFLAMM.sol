// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @notice Minimal surface of the Everlong FLAMM pool: an exact-input market between the pool
/// asset and loan asset 0, plus the leverage venue over the same book. The pool is the sole
/// entrypoint and approval target for every route — it pulls exactly `amountInUsed` with
/// transferFrom and pays the output to `to`.
interface IFLAMM {
  /// @notice Exact-input swap over (asset, a live loan asset). `amountIn` is a MAXIMUM: a sell
  ///         clipped by its ceiling (gate room, funding, notional cap) pulls only
  ///         `amountInUsed`; a fill outside the price band reverts rather than truncates.
  function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address to,
    uint256 deadline
  ) external returns (uint256 amountInUsed, uint256 amountOut);

  /// @notice Deliver pool asset, receive loan asset 0 net of the virtual leg the fill mints.
  function leverUp(uint256 poolAssetIn, uint256 minLoanOut, address to, uint256 deadline)
    external
    returns (uint256 amountInUsed, uint256 loanOut);

  /// @notice Pay loan asset 0, receive pool asset. `amountInUsed` is the loan asset actually
  ///         pulled — the fill's net pay leg rounded up, never above `loanIn`.
  function leverDown(uint256 loanIn, uint256 minPoolOut, address to, uint256 deadline)
    external
    returns (uint256 amountInUsed, uint256 poolOut);
}
