// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

library AmmalgamMath {
  function max(uint256 a, uint256 b) internal pure returns (uint256) {
    return a > b ? a : b;
  }

  function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
    return a == 0 ? 0 : (a - 1) / b + 1;
  }
}
