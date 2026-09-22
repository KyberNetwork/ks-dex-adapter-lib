// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import '../uniswap-v3/IUniswapV3Pool.sol';

/// @notice UnitFlow V3 pool state required for factory authentication.
interface IUnitFlowV3Pool is IUniswapV3Pool {
  function fee() external view returns (uint24);
}
