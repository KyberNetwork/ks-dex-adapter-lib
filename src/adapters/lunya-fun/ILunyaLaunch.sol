// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @notice The parts of a Lunya launch the adapter and its tests use. A launch sells its own token
///         against a quote token along a bonding curve, and pulls both legs with transferFrom.
interface ILunyaLaunch {
  function token() external view returns (address);

  function buy(uint256 amountIn, uint256 minTokensOut, uint256 deadline, address recipient)
    external
    returns (uint256 tokensOut);

  function sell(uint256 tokensIn, uint256 minAmountOut, uint256 deadline, address recipient)
    external
    returns (uint256 amountOut);

  function quoteBuy(uint256 amountIn)
    external
    view
    returns (uint256 tokensOut, uint256 fee, uint256 refund);

  function quoteSell(uint256 tokensIn) external view returns (uint256 amountOut, uint256 fee);
}
