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
/// @dev `data` is abi.encode(launchpad, token). A swap into `token` is a buy, anything else a
///      sell; a pair that doesn't match the curve reverts inside the launchpad. Native ETH goes in
///      as msg.value; anything else is pulled with transferFrom, so the launchpad is approved for
///      exactly the amount in. Both legs pay `msg.sender`, which is the executor that
///      delegatecalls this adapter, and return what was delivered. A buy spends the whole input,
///      so `amountUnused` is 0.
contract SlyngFunAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeSlyngFun(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address /* recipient */
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address launchpad, address token) = _decodeData(data);

    uint256 value;
    if (tokenIn.isNative()) {
      value = amountIn;
    } else {
      tokenIn.forceApprove(launchpad, amountIn);
    }

    if (tokenOut == token) {
      amountOut = ISlyngLaunchpad(launchpad).buy{value: value}(token, amountIn, 0);
    } else {
      amountOut = ISlyngLaunchpad(launchpad).sell(token, amountIn, 0);
    }
  }

  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address launchpad, address token)
  {
    launchpad = data.decodeAddress(0);
    token = data.decodeAddress(1);
  }
}
