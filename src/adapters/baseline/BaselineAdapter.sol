// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IBaseline.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract BaselineAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeBaseline(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address,
    address
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (address relay, address bToken, bool isBuy) = _decodeData(data);

    // Approve relay to pull tokenIn from this adapter
    tokenIn.forceApprove(relay, amountIn);

    if (isBuy) {
      // Buy: reserve -> bToken
      (amountOut,) = IBaseline(relay).buyTokensExactIn(bToken, amountIn, 1);
    } else {
      // Sell: bToken -> reserve
      (amountOut,) = IBaseline(relay).sellTokensExactIn(bToken, amountIn, 1);
    }

    amountUnused = 0;
  }

  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address relay, address bToken, bool isBuy)
  {
    relay = data.decodeAddress(0);
    bToken = data.decodeAddress(1);
    isBuy = data.decodeBool(2);
  }
}
