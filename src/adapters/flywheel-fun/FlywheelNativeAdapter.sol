// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import '../../libraries/TokenHelper.sol';
import './IFlywheelNative.sol';

/// @notice Execution module for the September 30 native-settlement factory only.
/// @dev Prefunded, atomic executor module following Kyber's adapter convention.
/// Not a custody vault: never leave user funds in this public adapter between calls.
/// Executor integration must permit ETH callbacks and must not call this module
/// while the shared Uniswap V4 PoolManager is already unlocked.
contract FlywheelNativeAdapter {
  using TokenHelper for address;

  address public constant FACTORY = 0xEE54DA52128dd851c71b1c58d371966231B66C40;
  address public constant SETTLEMENT = 0x04111c295399582B2B702Ad5De8d11be2B50dD5D;
  address public constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
  bytes32 private constant LOCK = keccak256('kyberswap.adapter.flywheel.native.reentrancy');

  struct Trade {
    address token;
    uint256 minQuote;
    uint256 minOutput;
    uint256 deadline;
    bytes route;
    uint256 minRefundETH;
    bytes refundRoute;
  }

  error InvalidTrade();
  error BalanceMismatch();
  error ReentrantCall();

  modifier guarded() {
    bytes32 slot = LOCK;
    bool locked;
    assembly ('memory-safe') { locked := tload(slot) }
    if (locked) revert ReentrantCall();
    assembly ('memory-safe') { tstore(slot, 1) }
    _;
    assembly ('memory-safe') { tstore(slot, 0) }
  }

  /// @dev data = abi.encode(Trade). Refunds remain as tokenIn in the executor;
  /// amountUnused reports only this trade's refund, excluding existing balances.
  function executeFlywheelNative(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable guarded returns (uint256 amountUnused, uint256 amountOut) {
    Trade memory trade = abi.decode(data, (Trade));
    bool buying = _isETH(tokenIn) && tokenOut == trade.token;
    bool selling = tokenIn == trade.token && _isETH(tokenOut);
    if (
      block.chainid != 4663 || amountIn == 0 || recipient == address(0) || recipient == SETTLEMENT
        || trade.token == WETH || trade.token.code.length == 0 || buying == selling
        || trade.minQuote == 0 || trade.minOutput == 0 || trade.deadline < block.timestamp
        || (!tokenIn.isNative() && msg.value != 0)
        || (trade.minRefundETH == 0 && trade.refundRoute.length != 0)
        || IFlywheelNativeToken(trade.token).factory() != FACTORY
    ) revert InvalidTrade();
    if (tokenIn.balanceOf(address(this)) < amountIn) revert BalanceMismatch();

    uint256 outputBefore = tokenOut.balanceOf(address(this));
    IFlywheelNativeSettlement settlement = IFlywheelNativeSettlement(SETTLEMENT);
    if (buying) {
      uint256 nativeBefore = address(this).balance;
      if (tokenIn == WETH) IFlywheelWETH(WETH).withdraw(amountIn);
      else nativeBefore -= amountIn;
      if (trade.minRefundETH == 0) {
        amountOut = settlement.buy{value: amountIn}(
          trade.token, trade.minQuote, trade.minOutput, trade.deadline, trade.route
        );
      } else {
        amountOut = settlement.buyWithRefund{value: amountIn}(
          trade.token,
          trade.minQuote,
          trade.minOutput,
          trade.deadline,
          trade.route,
          trade.minRefundETH,
          trade.refundRoute
        );
      }
      amountUnused = address(this).balance - nativeBefore;
      if (amountUnused > amountIn) revert BalanceMismatch();
      if (tokenIn == WETH && amountUnused > 0) IFlywheelWETH(WETH).deposit{value: amountUnused}();
    } else {
      if (trade.minRefundETH != 0) revert InvalidTrade();
      uint256 inputBefore = tokenIn.balanceOf(address(this));
      uint256 nativeBefore = address(this).balance;
      tokenIn.forceApprove(SETTLEMENT, amountIn);
      amountOut = settlement.sell(
        trade.token, amountIn, trade.minQuote, trade.minOutput, trade.deadline, trade.route
      );
      tokenIn.forceApprove(SETTLEMENT, 0);
      if (
        tokenIn.balanceOf(address(this)) != inputBefore - amountIn
          || address(this).balance != nativeBefore + amountOut
      ) revert BalanceMismatch();
      if (tokenOut == WETH) IFlywheelWETH(WETH).deposit{value: amountOut}();
    }
    if (
      amountOut < trade.minOutput || tokenOut.balanceOf(address(this)) != outputBefore + amountOut
    ) {
      revert BalanceMismatch();
    }
    if (recipient != address(this)) {
      uint256 recipientBefore = tokenOut.balanceOf(recipient);
      tokenOut.safeTransfer(recipient, amountOut);
      // An ETH recipient may forward its payment in receive(); a successful
      // transfer still delivered the exact value. ERC20 delivery remains exact.
      if (
        (!tokenOut.isNative() && tokenOut.balanceOf(recipient) != recipientBefore + amountOut)
          || tokenOut.balanceOf(address(this)) != outputBefore
      ) revert BalanceMismatch();
    }
  }

  function _isETH(address token) private pure returns (bool) {
    return token.isNative() || token == WETH;
  }

  receive() external payable {
    if (msg.sender != SETTLEMENT && msg.sender != WETH) revert InvalidTrade();
  }
}
