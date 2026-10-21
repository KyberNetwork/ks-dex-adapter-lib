// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import './AmmalgamMath.sol';
import './QuadraticSwapFees.sol';

uint256 constant BUFFER = 19;
uint256 constant BUFFER_NUMERATOR = 20;

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
