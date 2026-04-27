// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IBaseline.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract BaselineAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  function executeBaseline(bytes calldata data, uint256 amountIn, address tokenIn, address, address)
    external
    payable
    returns (uint256 amountUnused, uint256 amountOut)
  {
    (address relay, address bToken, bool isBuy, uint256 buyAmountOut) = _decodeData(data);

    // Approve relay to pull tokenIn from this adapter
    tokenIn.forceApprove(relay, amountIn);

    if (isBuy) {
      // Buy: reserve -> bToken via exactOut (avoids on-chain binary search)
      // amountIn acts as the slippage limit (max reserves to spend)
      (uint256 reservesSpent,) = IBaseline(relay).buyTokensExactOut(bToken, buyAmountOut, amountIn);
      amountOut = buyAmountOut;
      amountUnused = amountIn - reservesSpent;
    } else {
      // Sell: bToken -> reserve
      (amountOut,) = IBaseline(relay).sellTokensExactIn(bToken, amountIn, 1);
    }
  }

  function _decodeData(bytes calldata data)
    internal
    pure
    returns (address relay, address bToken, bool isBuy, uint256 buyAmountOut)
  {
    relay = data.decodeAddress(0);
    bToken = data.decodeAddress(1);
    isBuy = data.decodeBool(2);
    if (isBuy) {
      buyAmountOut = data.decodeUint256(3);
    }
  }
}
