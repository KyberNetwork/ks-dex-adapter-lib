// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './ISlyngLaunchpad.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title SlyngFunAdapter
/// @notice KyberSwap DEX adapter for coins on their bonding curve at Slyng, the launchpad on
///         Robinhood Chain (4663). One Launchpad contract holds every curve, keyed by the coin it
///         sells; a curve is priced in ETH or in a listed ERC-20 and trades only against the
///         launchpad until it graduates to a Uniswap v4 pool.
/// @dev `data` is abi.encode(launchpad, token). The direction follows from the tokens: a swap
///      into `token` is a buy, a swap out of it is a sell. The launchpad pays both legs to
///      `msg.sender`, so the output lands in this contract for the router to forward. A
///      native-quoted buy is paid as msg.value; an ERC-20 quote and a sold coin are pulled with
///      transferFrom, so the launchpad is approved for exactly the amount in. Nothing is
///      refunded on a buy: the launchpad spends every wei past the fee, so `amountUnused` is 0.
contract SlyngFunAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error NotThisCurve(address tokenIn, address tokenOut, address token);

  function executeSlyngFun(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address /* recipient */
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address launchpad, address token) = _decodeData(data);

    uint256 balanceOutBefore = tokenOut.selfBalance();

    if (tokenOut == token) {
      if (tokenIn.isNative()) {
        ISlyngLaunchpad(launchpad).buy{value: amountIn}(token, amountIn, 0);
      } else {
        tokenIn.forceApprove(launchpad, amountIn);
        ISlyngLaunchpad(launchpad).buy(token, amountIn, 0);
      }
    } else if (tokenIn == token) {
      tokenIn.forceApprove(launchpad, amountIn);
      ISlyngLaunchpad(launchpad).sell(token, amountIn, 0);
    } else {
      revert NotThisCurve(tokenIn, tokenOut, token);
    }

    amountUnused = 0;
    // measured rather than trusted, for a quote asset that skims its transfers
    amountOut = tokenOut.selfBalance() - balanceOutBefore;
  }

  /// @dev A sell of a native-quoted coin is paid in ETH by the launchpad.
  receive() external payable {}

  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address launchpad, address token)
  {
    launchpad = data.decodeAddress(0);
    token = data.decodeAddress(1);
  }
}
