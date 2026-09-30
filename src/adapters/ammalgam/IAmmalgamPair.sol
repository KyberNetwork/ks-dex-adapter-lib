// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.0;

interface IAmmalgamPair {
  function underlyingTokens() external view returns (address tokenX, address tokenY);

  function getReserves()
    external
    view
    returns (uint112 reserveXAssets, uint112 reserveYAssets, uint32 lastTimestamp);

  function referenceReserves()
    external
    view
    returns (uint112 referenceReserveX, uint112 referenceReserveY);

  function totalAssetsAndShares(bool withInterest)
    external
    view
    returns (uint112[6] memory allAssets, uint112[6] memory allShares);

  function swap(uint256 amountXOut, uint256 amountYOut, address to, bytes calldata data) external;
}
