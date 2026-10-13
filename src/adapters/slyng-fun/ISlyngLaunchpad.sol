// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice The part of Slyng's Launchpad an adapter needs. Every curve lives inside the one
///         contract, keyed by the token it sells; `buy` takes the quote asset and `sell` takes the
///         token, and both pay out to `msg.sender`.
interface ISlyngLaunchpad {
  /// @param amountIn Quote to spend. For a native-quoted coin it must equal `msg.value`; for an
  ///        ERC-20 quote `msg.value` must be zero and the launchpad pulls it with transferFrom.
  function buy(address token, uint256 amountIn, uint256 minTokensOut)
    external
    payable
    returns (uint256 tokensOut);

  function sell(address token, uint256 tokensIn, uint256 minQuoteOut)
    external
    returns (uint256 quoteOut);

  function curves(address token)
    external
    view
    returns (
      uint256 quoteReserve,
      uint256 tokenReserve,
      uint256 graduationTarget,
      uint256 virtualQuote,
      uint256 lpQuote,
      address quote,
      address creator,
      uint64 createdAt,
      bool exists,
      bool graduated
    );

  function quoteToTokens(address token, uint256 quoteIn) external view returns (uint256);
  function tokensToQuote(address token, uint256 tokensIn) external view returns (uint256);
  function snipeSurchargeBps(address token) external view returns (uint256);
  function TRADE_FEE_BPS() external view returns (uint256);

  function createToken(
    string calldata name,
    string calldata symbol,
    uint256 lockupSeconds,
    address quote,
    uint256 openingBuy
  ) external payable returns (address token);
}
