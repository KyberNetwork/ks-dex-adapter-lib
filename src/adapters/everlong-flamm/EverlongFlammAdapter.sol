// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import './IFLAMM.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title EverlongFlammAdapter
/// @notice KyberSwap DEX adapter for the Everlong FLAMM pool (`everlong-flamm`) on Base:
///         exact-input fills against the pool directly, over the pair (pool asset, loan
///         asset 0).
/// @dev One pool exposes a swap venue and a leverage venue on the same book, and `kind` picks
///      the entry: `swap` takes the (tokenIn, tokenOut) pair itself, `leverUp` delivers pool
///      asset for loan asset, `leverDown` pays loan asset for pool asset. The pool pulls
///      exactly what it reports as `amountInUsed` and pays the output to `recipient`, so a
///      clipped swap and a lever-down both leave the remainder in this frame. A lever-down's
///      remainder is not spare input: the fill is sized on the whole `amountIn` and only then
///      charged, so re-quoting the venue at `amountIn - amountUnused` returns materially less.
///      The venue-level minimum output is 1; KyberSwap's routing layer enforces minReturn.
contract EverlongFlammAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  /// @notice Execute an exact-input fill against a FLAMM pool.
  /// @param data ABI-encoded: (address pool, uint256 kind) — 0 = swap, 1 = leverUp, 2 = leverDown
  /// @param amountIn Amount of tokenIn (already in this contract)
  /// @param tokenIn Input token address
  /// @param tokenOut Output token address
  /// @param recipient Recipient of the output
  /// @return amountUnused Input the pool did not pull
  /// @return amountOut Amount of tokenOut paid to the recipient
  function executeEverlongFlamm(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address pool = data.decodeAddress(0);
    uint256 kind = data.decodeUint256(1); // 0 = swap, 1 = leverUp, 2 = leverDown

    tokenIn.forceApprove(pool, amountIn);

    uint256 amountInUsed;
    if (kind == 0) {
      (amountInUsed, amountOut) =
        IFLAMM(pool).swap(tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp);
    } else if (kind == 1) {
      (amountInUsed, amountOut) = IFLAMM(pool).leverUp(amountIn, 1, recipient, block.timestamp);
    } else {
      (amountInUsed, amountOut) = IFLAMM(pool).leverDown(amountIn, 1, recipient, block.timestamp);
    }

    amountUnused = amountIn - amountInUsed;
  }
}
