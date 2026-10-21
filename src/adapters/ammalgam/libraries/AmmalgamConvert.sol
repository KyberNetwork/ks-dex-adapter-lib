// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

import './AmmalgamMath.sol';

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
