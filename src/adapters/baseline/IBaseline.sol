// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IBaseline {
  /// @notice Buy bTokens with exact reserve input
  /// @param bToken The bToken to buy
  /// @param amountIn The amount of reserve tokens to spend
  /// @param limitAmount The minimum amount of bTokens to receive
  /// @return amountOut The amount of bTokens received
  /// @return feesReceived The fees collected
  function buyTokensExactIn(address bToken, uint256 amountIn, uint256 limitAmount)
    external
    returns (uint256 amountOut, uint256 feesReceived);

  /// @notice Buy exact amount of bTokens
  /// @param bToken The bToken to buy
  /// @param amountOut The exact amount of bTokens to receive
  /// @param limitAmount The maximum amount of reserve tokens to spend
  /// @return amountIn The amount of reserve tokens spent
  /// @return feesReceived The fees collected
  function buyTokensExactOut(address bToken, uint256 amountOut, uint256 limitAmount)
    external
    payable
    returns (uint256 amountIn, uint256 feesReceived);

  /// @notice Quote buying tokens with exact reserves input
  /// @param bToken The bToken to buy
  /// @param reservesIn The amount of reserve tokens to spend
  /// @return tokensOut The amount of bTokens that would be received
  /// @return feesReceived The fees collected
  /// @return slippage The price impact
  function quoteBuyExactIn(address bToken, uint256 reservesIn)
    external
    view
    returns (uint256 tokensOut, uint256 feesReceived, uint256 slippage);

  /// @notice Sell exact bTokens for reserve
  /// @param bToken The bToken to sell
  /// @param amountIn The amount of bTokens to sell
  /// @param limitAmount The minimum amount of reserve tokens to receive
  /// @return amountOut The amount of reserve tokens received
  /// @return feesReceived The fees collected
  function sellTokensExactIn(address bToken, uint256 amountIn, uint256 limitAmount)
    external
    returns (uint256 amountOut, uint256 feesReceived);
}
