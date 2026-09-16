// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import './IFLAMM.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @notice Adapter for the Everlong FLAMM pool (`everlong-flamm`): exact-input fills against
/// the pool directly, over the pair (pool asset, loan asset 0) read from the pool itself.
/// One pool exposes two venues on the same book:
///
///   - venue 0, swap: `swap(tokenIn, tokenOut, ...)` in either direction. A fill clipped by
///     its output ceiling takes only part of the input — a sell's is the gate room, funding
///     and the loan asset's notional cap, a buy's the pool asset the book holds — while a
///     buy past the notional cap and either direction past the price band revert;
///   - venue 1, leverage: asset -> loan asset is `leverUp` (all or nothing), loan asset ->
///     asset is `leverDown`, which pulls only the fill's net pay leg (rounded up) out of
///     `amountIn`.
///
/// The pool pulls exactly what it reports as used, so the remainder surfaces through
/// `amountUnused` and is still held by this frame when the call returns. Output is paid by
/// the pool straight to `recipient`. The venue-level minimum output is `1`, because the
/// production route executor enforces the user's aggregate `minReturn`; a direct adapter call
/// has no meaningful per-venue slippage protection.
///
/// A lever-down's remainder is not spare input: `FLAMMLeverLib.sol:125-141` sizes the fill on
/// the whole `amountIn` and only then charges `payNative`, so re-quoting the venue at
/// `amountIn - amountUnused` returns materially less output. The remainder is headroom the
/// fill needs, not input the venue declined.
///
/// Both legs are ERC-20; a native input or output token is refused. `msg.value` is NOT
/// checked: the route executor DELEGATECALLs adapters, so this code runs in the executor's
/// context and every hop of a native-input route sees the route's `msg.value`, including the
/// ERC-20 hops after the wrap. The remainder therefore returns to the executor rather than to
/// the caller of the route, and it does not stay there: Kyber's Base executor
/// 0x8F10B468b06c6FD214B65F87778827F7D113f996 transfers the `tokenIn` still on it at the end
/// of the sequence to the collector address in its own storage (slot
/// 0xba0a5ab76d98f9ac10ca45e75e95f468a2d74cf2262a11f750fdd59b147ea301, holding
/// 0x8609303C2e7E63278a5aC9F7A99F99cdEdB8612f at Base block 51_365_945), it never reads the
/// `amountUnused` returned here, and it refunds nothing in the same transaction. A hop sized
/// above what the venue will take therefore costs the user the remainder.
///
/// `data` layout, at least 64 bytes — a shorter blob is refused rather than read as venue 0:
///   word 0: FLAMM pool address
///   word 1: venue (0 = swap, 1 = leverage)
contract EverlongFlammAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error EverlongFlammAdapter_InvalidData();
  error EverlongFlammAdapter_Misreport();
  error EverlongFlammAdapter_NativeUnsupported();
  error EverlongFlammAdapter_TokenMismatch();
  error EverlongFlammAdapter_UnknownVenue();

  uint256 private constant VENUE_SWAP = 0;
  uint256 private constant VENUE_LEVERAGE = 1;

  function executeEverlongFlamm(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    if (tokenIn.isNative() || tokenOut.isNative()) {
      revert EverlongFlammAdapter_NativeUnsupported();
    }
    // `decodeUint256` reads calldata unchecked, so a one-word blob would read whatever
    // follows it — zero at the end of the calldata — as venue 0 and silently run the swap
    // venue instead of refusing.
    if (data.length < 64) revert EverlongFlammAdapter_InvalidData();
    address pool = data.decodeAddress(0);
    uint256 venue = data.decodeUint256(1);
    if (venue > VENUE_LEVERAGE) revert EverlongFlammAdapter_UnknownVenue();

    // Bind BOTH legs to the pool's own getters. `data` is caller-supplied, so a pair the
    // pool does not trade must fail here rather than select the opposite leverage leg.
    // There is deliberately no factory membership check: it would pin the adapter to one
    // chain's factory, and it is not what bounds the exposure. A foreign `pool` cannot
    // settle this call having moved more than its input: the allowance is sized to it and
    // cleared below, and the balance delta must match the reported fill, itself capped at
    // `amountIn`.
    address poolAsset = IFLAMM(pool).asset();
    address loanAsset = IFLAMM(pool).loanAsset();
    bool sell = tokenIn == poolAsset && tokenOut == loanAsset;
    if (!sell && !(tokenIn == loanAsset && tokenOut == poolAsset)) {
      revert EverlongFlammAdapter_TokenMismatch();
    }

    uint256 balanceBefore = tokenIn.selfBalance();
    tokenIn.forceApprove(pool, amountIn);

    uint256 amountInUsed;
    if (venue == VENUE_SWAP) {
      (amountInUsed, amountOut) =
        IFLAMM(pool).swap(tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp);
    } else if (sell) {
      (amountInUsed, amountOut) = IFLAMM(pool).leverUp(amountIn, 1, recipient, block.timestamp);
    } else {
      (amountInUsed, amountOut) = IFLAMM(pool).leverDown(amountIn, 1, recipient, block.timestamp);
    }

    // Clear UNCONDITIONALLY: partial fills and lever-downs leave allowance unspent by
    // design, and whether anything was pulled is the pool's own report.
    tokenIn.forceApprove(pool, 0);

    // The report must match what actually left the adapter. The pool balance-checks its
    // own pull, but `pool` came from `data`; a target that under- or over-reports, or hands
    // input back, would otherwise turn into a wrong `amountUnused` for the route. The delta
    // is this frame's own, so the guard binds one non-nested call: a `pool` that reenters
    // this function settles the inner fill out of the same balance and the same allowance,
    // and both frames see that one pull. Each still has to equal its own report and stay
    // within its own `amountIn` — no frame settles having moved more than its input — but two
    // nested frames can attribute a single pull twice (see the adversarial suite).
    uint256 balanceAfter = tokenIn.selfBalance();
    if (
      balanceAfter > balanceBefore || balanceBefore - balanceAfter != amountInUsed
        || amountInUsed > amountIn
    ) revert EverlongFlammAdapter_Misreport();

    amountUnused = amountIn - amountInUsed;
  }
}
