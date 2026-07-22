// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IPartyPool.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title LiquidityPartyAdapter
/// @notice KyberSwap adapter for Liquidity Party ("LiqP") LMSR multi-asset pools.
/// @dev A LiqP pool holds `n` tokens and quotes any ordered pair `(i -> j)` off a shared LMSR
///      `q`-vector. The router selects the single pair to swap; the off-chain dex-lib simulator
///      emits the `(indexIn, indexOut)` indices via GetMetaInfo, which the (off-repo) KyberSwap
///      calldata encoder abi-encodes into `data`. We use word-aligned `abi.encode` + CalldataDecoder
///      to match the other adapters (uniswap-v2/v3, wasabi) — the house convention the encoder emits.
///
///      Funding uses PREFUNDING (0x00000001): the input token is transferred into the pool and
///      `swap()` is called atomically in the same tx. PREFUNDING funds from an unauthenticated
///      balance delta, so it is only safe when the transfer and the swap are atomic — which they
///      are here. The pool requires `msg.sender == payer` on the PREFUNDING path, so `payer` is
///      this adapter. The fee is charged on the OUTPUT side, so the full `amountIn` is consumed
///      (no fee-on-transfer / rebasing tokens: admin-created pools reject them).
contract LiquidityPartyAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  /// @notice Funding.PREFUNDING selector — input already sent to the pool before swap().
  /// @dev Must match Funding.PREFUNDING in ../lmsr-amm/src/Funding.sol.
  bytes4 internal constant FUNDING_PREFUNDING = 0x00000001;

  /// @param data      abi.encode(address pool, uint256 indexIn, uint256 indexOut) (3 words).
  /// @param amountIn  input already prefunded to this adapter by the executor.
  /// @param tokenIn   input token address (LiqP token at `indexIn`).
  /// @param recipient address that receives the output tokens.
  /// @dev The 4th arg (tokenOut) is unused: swap() returns the net output directly. It is kept in
  ///      the signature for the uniform execute<Dex>(bytes, uint256, address, address, address) ABI.
  function executeLiquidityParty(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address pool, uint256 indexIn, uint256 indexOut) = _decodeData(data);

    // push the prefunded input into the pool, then swap atomically (PREFUNDING requires atomicity).
    // swap() returns the net output (gross minus outFee) sent to the recipient, so use it directly.
    // LiqP rejects fee-on-transfer / rebasing tokens (pool-side balance checks), so this equals the
    // recipient balance diff to the wei — no extra balanceOf needed (asserted in the fork test).
    tokenIn.safeTransfer(pool, amountIn);
    (, amountOut,) = IPartyPool(pool)
      .swap(
        address(this), // payer == msg.sender, required by the PREFUNDING path
        FUNDING_PREFUNDING,
        recipient, // deliver net output directly to the recipient
        indexIn,
        indexOut,
        amountIn,
        0, // minAmountOut: the router enforces slippage
        0, // deadline: the router enforces deadlines
        false, // unwrap: KyberSwap handles native (un)wrapping, so treat LiqP as ERC-only
        '' // no callback data for PREFUNDING
      );

    // LiqP consumes exactly maxAmountIn; there is no fee-on-transfer, so nothing is left unused.
    // amountUnused = 0; // Save gas by relying on the implicit initialization to zero
  }

  /// @dev Word-aligned layout matching the other adapters: abi.encode(pool, indexIn, indexOut).
  ///      The off-repo KyberSwap encoder must emit exactly this (same shape as uniswap-v2's
  ///      abi.encode(pool, fee, feeDenom)).
  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address pool, uint256 indexIn, uint256 indexOut)
  {
    pool = data.decodeAddress(0);
    indexIn = data.decodeUint256(1);
    indexOut = data.decodeUint256(2);
  }
}
