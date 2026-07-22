// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @title IPartyPool
/// @notice Minimal interface for a Liquidity Party (LMSR) PartyPool — the swap entry point only.
/// @dev The signature and selector (0x4ae93e1d) match the deployed mainnet pool
///      (see ../lmsr-amm/src/IPartyPool.sol). Note this differs from an earlier revision of the
///      protocol that used `int128 limitPrice` in place of `uint256 minAmountOut`; the deployed
///      pools we integrate use `minAmountOut`. The fee is charged on the OUTPUT side, so
///      `maxAmountIn` is the exact gross input transferred (nothing is added for fees).
interface IPartyPool {
  /// @param payer            account that pays the input; for PREFUNDING it MUST equal msg.sender
  ///                         (the pool enforces `require(msg.sender == payer, "prefunding: caller != payer")`).
  /// @param fundingSelector  Funding.PREFUNDING (0x00000001): input already transferred to the pool.
  /// @param receiver         address that receives the net output tokens.
  /// @param inputTokenIndex  index of the input asset in the pool's token list.
  /// @param outputTokenIndex index of the output asset in the pool's token list.
  /// @param maxAmountIn      exact input to consume (fee is on the output side, not added to input).
  /// @param minAmountOut     minimum net output; reverts "slippage control" if not met. Pass 0 to disable.
  /// @param deadline         timestamp after which the call reverts; pass 0 to ignore.
  /// @param unwrap           if true, native-wrapper output is unwrapped to native currency.
  /// @param cbData           callback data for callback-style funding selectors (empty for PREFUNDING).
  /// @return amountIn  actual input consumed.
  /// @return amountOut net output sent to receiver (gross output minus outFee).
  /// @return outFee    fee taken from the gross output.
  function swap(
    address payer,
    bytes4 fundingSelector,
    address receiver,
    uint256 inputTokenIndex,
    uint256 outputTokenIndex,
    uint256 maxAmountIn,
    uint256 minAmountOut,
    uint256 deadline,
    bool unwrap,
    bytes memory cbData
  ) external payable returns (uint256 amountIn, uint256 amountOut, uint256 outFee);
}
