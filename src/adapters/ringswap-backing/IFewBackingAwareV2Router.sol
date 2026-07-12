// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IFewBackingAwareV2Router {
  function origin0() external view returns (address);

  function origin1() external view returns (address);

  function routeConfig()
    external
    view
    returns (
      address pairAddress,
      address wrapper0,
      address wrapper1,
      address originToken0,
      address originToken1
    );

  function swapExactInput(
    address originIn,
    uint256 amountIn,
    uint256 amountOutMin,
    address recipient,
    uint256 deadline
  ) external returns (uint256 amountOut, bool usedRecall);
}

interface IFewBackingWrappedToken {
  function wrapTo(uint256 amount, address recipient) external returns (uint256 wrapped);

  function unwrapTo(uint256 amount, address recipient) external returns (uint256 unwrapped);
}

interface IRingSwapBackingPair {
  function getReserves()
    external
    view
    returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

  function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
