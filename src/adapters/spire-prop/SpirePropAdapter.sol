// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';
import './ISpireEntrypoint.sol';

/// @notice Executes exact-input trades against Spire's on-chain curve and shared custodian.
contract SpirePropAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error InvalidData();
  error InvalidTokenPair();
  error NativeNotSupported();

  /// @notice Spends input already transferred to this adapter and pays output directly to recipient.
  /// @dev The enclosing Kyber route enforces its overall minimum output and deadline.
  ///      Spire independently enforces the authenticated curve expiry and available liquidity.
  /// @param data ABI encoding of (entrypoint, base), two address words.
  /// @param amountIn Exact input amount already held by this adapter.
  /// @param tokenIn ERC20 input token, either base or the entrypoint's quote token.
  /// @param tokenOut The other ERC20 token of the pair.
  /// @param recipient Address receiving output directly from Spire custody.
  /// @return amountUnused Always zero on success; Spire consumes the entire input.
  /// @return amountOut Actual output received by recipient.
  function executeSpireProp(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    if (data.length != 64) revert InvalidData();
    if (msg.value != 0 || tokenIn.isNative() || tokenOut.isNative()) revert NativeNotSupported();
    address entrypoint = data.decodeAddress(0);
    address base = data.decodeAddress(1);
    address quote = ISpireEntrypoint(entrypoint).quoteToken();
    if (
      base == address(0) || base == quote
        || !((tokenIn == base && tokenOut == quote) || (tokenIn == quote && tokenOut == base))
    ) revert InvalidTokenPair();

    tokenIn.forceApprove(entrypoint, amountIn);
    uint256 balanceBefore = tokenOut.balanceOf(recipient);
    ISpireEntrypoint(entrypoint).swapExactAmountIn(base, tokenIn, amountIn, 1, recipient);
    amountOut = tokenOut.balanceOf(recipient) - balanceBefore;
    amountUnused = 0;
  }
}
