// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import './AmmalgamConvert.sol';
import './AmmalgamMath.sol';

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
