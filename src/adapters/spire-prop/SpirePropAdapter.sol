// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';
import './ISpireEntrypoint.sol';

/// @notice Executes exact-input trades against Spire's on-chain curve and shared custodian.
contract SpirePropAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  /// @notice Spends input already held by this adapter and pays output directly to recipient.
  /// @dev The enclosing Kyber route enforces its overall minimum output and deadline.
  ///      Spire validates the pair and enforces curve expiry and available liquidity.
  /// @param data ABI encoding of (entrypoint, base).
  /// @param amountIn Exact input amount already held by this adapter.
  /// @param tokenIn Either the base or the entrypoint's quote token.
  /// @param recipient Address receiving output directly from Spire custody.
  /// @return amountUnused Always zero; Spire consumes the entire input.
  /// @return amountOut Output paid to recipient.
  function executeSpireProp(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address entrypoint = data.decodeAddress(0);
    tokenIn.forceApprove(entrypoint, amountIn);
    amountOut = ISpireEntrypoint(entrypoint)
      .swapExactAmountIn(data.decodeAddress(1), tokenIn, amountIn, 1, recipient);
  }
}
