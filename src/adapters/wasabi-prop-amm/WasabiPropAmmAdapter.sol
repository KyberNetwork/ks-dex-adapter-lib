// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IPropPool.sol';
import './IWETH.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

contract WasabiPropAmmAdapter {
  using TokenHelper for address;
  using CalldataDecoder for bytes;

  error InvalidMsgValue();

  address public immutable WETH;

  constructor(address _weth) {
    WETH = _weth;
  }

  receive() external payable {}

  function executeWasabiPropAmm(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address pool = data.decodeAddress(0);

    // Resolve actual ERC20 token address for input (native ETH -> WETH)
    address actualTokenIn = tokenIn.isNative() ? WETH : tokenIn;

    // Wrap native ETH to WETH if needed
    if (tokenIn.isNative()) {
      if (msg.value != amountIn) revert InvalidMsgValue();
      IWETH(WETH).deposit{value: amountIn}();
    } else if (msg.value != 0) {
      revert InvalidMsgValue();
    }

    // Approve pool to pull tokenIn from this adapter
    actualTokenIn.forceApprove(pool, amountIn);

    // Execute swap -- pool pulls tokenIn, sends tokenOut back to this contract
    amountOut = IPropPool(pool).swapExactInput(actualTokenIn, amountIn, 1);

    // Only explicitly transfer if native ETH is requested as output;
    // ERC20 outputs are left in the adapter for the framework to collect
    if (tokenOut.isNative()) {
      IWETH(WETH).withdraw(amountOut);
      TokenHelper.safeTransferNative(recipient, amountOut);
    }

    amountUnused = 0; // PropPool exact-input always consumes full amount
  }
}
