// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'src/adapters/everlong-flamm/EverlongFlammAdapter.sol';

/// @notice Stand-in for the production route executor, which DELEGATECALLs adapters from a
/// payable frame: the adapter runs in THIS contract's context (its balances, its allowances)
/// and sees this frame's `msg.value` on every hop, the ERC-20 hops of a native-input route
/// included.
contract DelegatecallExecutor {
  function execute(
    address adapter,
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    (bool ok, bytes memory ret) = adapter.delegatecall(
      abi.encodeCall(
        EverlongFlammAdapter.executeEverlongFlamm, (data, amountIn, tokenIn, tokenOut, recipient)
      )
    );
    if (!ok) {
      assembly ('memory-safe') {
        revert(add(ret, 0x20), mload(ret))
      }
    }
    return abi.decode(ret, (uint256, uint256));
  }
}
