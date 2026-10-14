// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import './IAmmalgamPair.sol';
import './libraries/AmmalgamMath.sol';
import './libraries/DepletedAssetUtils.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract AmmalgamAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error InvalidDataLength();

  uint256 private constant DEPOSIT_X = 1;
  uint256 private constant DEPOSIT_Y = 2;
  uint256 private constant BORROW_X = 4;
  uint256 private constant BORROW_Y = 5;

  /// @dev `data` is `abi.encode(pool)`.
  function executeAmmalgam(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    if (data.length != 32) revert InvalidDataLength();

    IAmmalgamPair pair = IAmmalgamPair(data.decodeAddress(0));
    bool xToY = tokenIn < tokenOut;

    amountOut = _computeExpectedSwapOutAmount(amountIn, pair, xToY);

    tokenIn.safeTransfer(address(pair), amountIn);

    if (xToY) {
      pair.swap(0, amountOut, recipient, '');
    } else {
      pair.swap(amountOut, 0, recipient, '');
    }
  }

  function _computeExpectedSwapOutAmount(uint256 amountIn, IAmmalgamPair pair, bool xToY)
    internal
    returns (uint256 amountOut)
  {
    // Apply pending observations and lending interest before reading the quote state. The
    // subsequent swap sees the same checkpointed reserves, reference reserves, and missing assets.
    pair.sync();

    (uint112 reserveX, uint112 reserveY,) = pair.getReserves();
    (uint112 referenceReserveX, uint112 referenceReserveY) = pair.referenceReserves();
    (uint256 missingX, uint256 missingY) = _pairMissingAssets(pair);

    uint256 reserveIn = xToY ? reserveX : reserveY;
    uint256 reserveOut = xToY ? reserveY : reserveX;
    uint256 referenceReserveIn = xToY ? referenceReserveX : referenceReserveY;
    uint256 missingIn = xToY ? missingX : missingY;
    uint256 missingOut = xToY ? missingY : missingX;

    amountOut = DepletedAssetUtils.computeExpectedSwapOutAmount(
      amountIn, reserveIn, referenceReserveIn, reserveOut, missingIn, missingOut
    );
  }

  function _pairMissingAssets(IAmmalgamPair pair)
    private
    view
    returns (uint256 missingX, uint256 missingY)
  {
    (uint112[6] memory allAssets,) = pair.totalAssetsAndShares(false);
    missingX = AmmalgamMath.max(allAssets[BORROW_X], allAssets[DEPOSIT_X]) - allAssets[DEPOSIT_X];
    missingY = AmmalgamMath.max(allAssets[BORROW_Y], allAssets[DEPOSIT_Y]) - allAssets[DEPOSIT_Y];
  }
}
