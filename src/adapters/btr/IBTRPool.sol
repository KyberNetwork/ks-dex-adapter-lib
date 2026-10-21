// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Subset of the BTR AIMM pool interface (`IPool`).
interface IBTRPool {
  /// @dev Mirrors `IPool.SwapQuote`. `amountOut` is the only field the adapter test reads.
  struct SwapQuote {
    uint256 amountOut;
    uint256 amountIn;
    uint16 spreadPbps;
    uint256 protoFee;
    uint256 lpFee;
    int8 skewIn;
    int8 skewOut;
    uint256 markPrice;
    uint256 midPrice;
    uint256 covToll;
    address[] routeHops;
    uint256[] hopAmounts;
    uint256[] hopPrices;
  }

  /// @notice Exact-in swap. Pulls `amountIn` of `tokenIn` from `msg.sender`, pays `tokenOut` to
  ///         `recipient`. Reverts `NotAuthorized()` when a leg is `SWAP_GATED` and the caller
  ///         lacks the swap lane, `Expired()` past `deadline`.
  function swap_qe(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline
  ) external payable returns (uint256 out);

  /// @notice Quote only, not an execution guarantee (skips the swap-enable/gate/liquidity guards).
  function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn)
    external
    view
    returns (SwapQuote memory);

  function getRiskFlags(address token) external view returns (uint16);
}
