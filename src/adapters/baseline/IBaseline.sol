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
