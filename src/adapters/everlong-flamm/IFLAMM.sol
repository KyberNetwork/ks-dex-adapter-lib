// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

/// @notice Minimal surface of the Everlong FLAMM pool: an exact-input market between the pool
/// asset and loan asset 0, plus the leverage venue over the same book. The pool is the sole
/// entrypoint and approval target for every route — it pulls the input with transferFrom
/// (exactly `amountInUsed`, balance-checked on its side) and pays the output to `to`.
interface IFLAMM {
  /// @notice The pool asset (the volatile leg).
  function asset() external view returns (address);

  /// @notice Loan asset 0: the numeraire and the pair every periphery binding uses.
  function loanAsset() external view returns (address);

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
