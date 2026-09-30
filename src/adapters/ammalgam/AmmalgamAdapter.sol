// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import './IAmmalgamPair.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

uint256 constant BUFFER = 19;
uint256 constant BUFFER_NUMERATOR = 20;

contract AmmalgamAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  uint256 private constant DEPOSIT_X = 1;
  uint256 private constant DEPOSIT_Y = 2;
  uint256 private constant BORROW_X = 4;
  uint256 private constant BORROW_Y = 5;

  error InvalidSwapPath(address tokenIn, address tokenOut, address tokenX, address tokenY);

  function executeAmmalgam(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    IAmmalgamPair pair = IAmmalgamPair(data.decodeAddress(0));
    (address tokenX, address tokenY) = pair.underlyingTokens();

    uint256 expectedAmountOut;
    bool xToY;
    if (tokenIn == tokenX && tokenOut == tokenY) {
      xToY = true;
      expectedAmountOut = _computeExpectedSwapOutAmountXToY(amountIn, pair);
    } else if (tokenIn == tokenY && tokenOut == tokenX) {
      expectedAmountOut = _computeExpectedSwapOutAmountYToX(amountIn, pair);
    } else {
      revert InvalidSwapPath(tokenIn, tokenOut, tokenX, tokenY);
    }

    uint256 balanceOutBefore = tokenOut.balanceOf(recipient);
    tokenIn.safeTransfer(address(pair), amountIn);

    if (xToY) {
      pair.swap(0, expectedAmountOut, recipient, '');
    } else {
      pair.swap(expectedAmountOut, 0, recipient, '');
    }

    amountUnused = 0;
    amountOut = tokenOut.balanceOf(recipient) - balanceOutBefore;
  }

  function _computeExpectedSwapOutAmountXToY(uint256 amountIn, IAmmalgamPair pair)
    private
    view
    returns (uint256 amountOut)
  {
    (uint112 reserveIn, uint112 reserveOut,) = pair.getReserves();
    (uint112 referenceReserveIn,) = pair.referenceReserves();
    (uint256 missingIn, uint256 missingOut) = _pairMissingAssets(pair);

    amountOut = DepletedAssetUtils.computeExpectedSwapOutAmount(
      amountIn, reserveIn, referenceReserveIn, reserveOut, missingIn, missingOut
    );
  }

  function _computeExpectedSwapOutAmountYToX(uint256 amountIn, IAmmalgamPair pair)
    private
    view
    returns (uint256 amountOut)
  {
    (uint112 reserveOut, uint112 reserveIn,) = pair.getReserves();
    (, uint112 referenceReserveIn) = pair.referenceReserves();
    (uint256 missingOut, uint256 missingIn) = _pairMissingAssets(pair);

    amountOut = DepletedAssetUtils.computeExpectedSwapOutAmount(
      amountIn, reserveIn, referenceReserveIn, reserveOut, missingIn, missingOut
    );
  }

  function _pairMissingAssets(IAmmalgamPair pair)
    private
    view
    returns (uint256 missingX, uint256 missingY)
  {
    (uint112[6] memory allAssets,) = pair.totalAssetsAndShares(true);
    missingX = _missingAssets(allAssets[BORROW_X], allAssets[DEPOSIT_X]);
    missingY = _missingAssets(allAssets[BORROW_Y], allAssets[DEPOSIT_Y]);
  }

  function _missingAssets(uint256 borrowAssets, uint256 depositAssets)
    private
    pure
    returns (uint256)
  {
    return AmmalgamMath.max(borrowAssets, depositAssets) - depositAssets;
  }
}

library DepletedAssetUtils {
  error MissingGteActual();

  function computeExpectedSwapOutAmount(
    uint256 amountIn,
    uint256 reserveIn,
    uint256 referenceReserveIn,
    uint256 reserveOut,
    uint256 missingIn,
    uint256 missingOut
  ) internal pure returns (uint256 amountOut) {
    uint256 adjustedReserveIn = _calculateBalanceAfterFees(
      amountIn, reserveIn + amountIn, reserveIn, referenceReserveIn, missingIn
    );
    uint256 newReserveOut = _computeCurveFromAdjustedInput(
      adjustedReserveIn, reserveIn, reserveOut, missingIn, missingOut
    );
    amountOut = reserveOut - newReserveOut;
  }

  function _computeCurveFromAdjustedInput(
    uint256 adjustedInput,
    uint256 reserveIn,
    uint256 reserveOut,
    uint256 missingIn,
    uint256 missingOut
  ) private pure returns (uint256 result) {
    uint256 adjustedReserveIn = actualToAdjusted(reserveIn, missingIn);
    uint256 adjustedReserveOut = actualToAdjusted(reserveOut, missingOut);

    uint256 firstAdjusted =
      AmmalgamMath.ceilDiv(adjustedReserveIn * adjustedReserveOut, adjustedInput);
    result = adjustedToActual(firstAdjusted, missingOut);
  }

  function _calculateBalanceAfterFees(
    uint256 amountIn,
    uint256 balance,
    uint256 reserve,
    uint256 referenceReserve,
    uint256 missing
  ) private pure returns (uint256 calculatedBalance) {
    uint256 fee = QuadraticSwapFees.calculateSwapFeeBipsQ64(amountIn, reserve, referenceReserve);

    if (balance * BUFFER < missing * BUFFER_NUMERATOR) {
      calculatedBalance = ((balance - missing) * QuadraticSwapFees.BIPS_Q64 - amountIn * fee)
        * BUFFER_NUMERATOR / QuadraticSwapFees.BIPS_Q64;
    } else {
      calculatedBalance =
        (balance * QuadraticSwapFees.BIPS_Q64 - amountIn * fee) / QuadraticSwapFees.BIPS_Q64;
    }
  }

  function actualToAdjusted(uint256 actual, uint256 missing)
    private
    pure
    returns (uint256 adjusted)
  {
    if (missing >= actual) revert MissingGteActual();

    if (missing * BUFFER_NUMERATOR < actual * BUFFER) {
      adjusted = actual * (BUFFER_NUMERATOR - BUFFER);
    } else {
      adjusted = (actual - missing) * BUFFER_NUMERATOR;
    }
  }

  function adjustedToActual(uint256 adjusted, uint256 missing)
    private
    pure
    returns (uint256 actual)
  {
    if (
      missing * BUFFER_NUMERATOR
        < AmmalgamMath.ceilDiv(adjusted, BUFFER_NUMERATOR - BUFFER) * BUFFER
    ) {
      actual = AmmalgamMath.ceilDiv(adjusted, BUFFER_NUMERATOR - BUFFER);
    } else {
      actual = AmmalgamMath.ceilDiv(adjusted, BUFFER_NUMERATOR) + missing;
    }
  }
}

library QuadraticSwapFees {
  uint256 public constant MIN_FEE_Q64 = 0x1999999999999999;
  uint256 public constant BIPS_Q64 = 0x27100000000000000000;

  uint256 internal constant MAX_QUADRATIC_FEE_PERCENT = 40;
  uint256 internal constant N = 20;

  uint256 private constant RESERVE_MULTIPLIER = 2;
  uint256 private constant LINEAR_START_REFERENCE_SCALER = 4;
  uint256 private constant MAX_QUADRATIC_FEE_PERCENT_BIPS = 4000;
  uint256 private constant N_TIMES_BIPS_Q64_PER_PERCENT = 0x7d00000000000000000;
  uint256 private constant TWO_Q64 = 0x20000000000000000;
  uint256 private constant MAX_QUADRATIC_FEE_Q64 = 0x280000000000000000;

  function calculateSwapFeeBipsQ64(uint256 input, uint256 currentReserve, uint256 referenceReserve)
    internal
    pure
    returns (uint256 fee)
  {
    if (input == 0) return 0;

    unchecked {
      uint256 currentReserveAfterSwap = input + currentReserve;
      if (currentReserve >= referenceReserve) {
        if (
          currentReserveAfterSwap + currentReserve
            > referenceReserve * LINEAR_START_REFERENCE_SCALER
        ) {
          fee = calculateLinearFeeBipsQ64(input, currentReserve, referenceReserve);
        } else {
          fee = calculateQuadraticFeeBipsQ64(input, currentReserve, referenceReserve);
        }
      } else if (currentReserveAfterSwap > referenceReserve) {
        uint256 pastBy = currentReserveAfterSwap - referenceReserve;

        if (pastBy > RESERVE_MULTIPLIER * referenceReserve) {
          fee = calculateLinearFeeBipsQ64(pastBy, referenceReserve, referenceReserve);
        } else {
          fee = calculateQuadraticFeeBipsQ64(pastBy, referenceReserve, referenceReserve);
        }

        fee = AmmalgamConvert.mulDiv(fee, pastBy, input, false);
      }
    }

    fee = AmmalgamMath.max(fee, MIN_FEE_Q64);
  }

  function calculateQuadraticFeeBipsQ64(
    uint256 input,
    uint256 currentReserve,
    uint256 referenceReserve
  ) private pure returns (uint256 fee) {
    fee = AmmalgamConvert.mulDiv(
      N_TIMES_BIPS_Q64_PER_PERCENT,
      input + RESERVE_MULTIPLIER * (currentReserve - referenceReserve),
      referenceReserve,
      false
    );
  }

  function calculateLinearFeeBipsQ64(
    uint256 input,
    uint256 currentReserve,
    uint256 referenceReserve
  ) private pure returns (uint256 fee) {
    fee = MAX_QUADRATIC_FEE_PERCENT_BIPS
      * (
        TWO_Q64
          - AmmalgamConvert.mulDiv(
            referenceReserve,
            MAX_QUADRATIC_FEE_Q64,
            N * (input + RESERVE_MULTIPLIER * (currentReserve - referenceReserve)),
            false
          )
      );
  }
}

library AmmalgamConvert {
  function mulDiv(uint256 x, uint256 y, uint256 z, bool roundingUp)
    internal
    pure
    returns (uint256 result)
  {
    result = x * y;
    result = roundingUp ? AmmalgamMath.ceilDiv(result, z) : result / z;
  }
}

library AmmalgamMath {
  function max(uint256 a, uint256 b) internal pure returns (uint256) {
    return a > b ? a : b;
  }

  function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    return a == 0 ? 0 : (a - 1) / b + 1;
  }
}
