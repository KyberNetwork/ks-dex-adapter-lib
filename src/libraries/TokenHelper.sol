// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {CustomRevert} from './CustomRevert.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/interfaces/IERC20.sol';

/// @title Library for transferring, approving and holding native tokens and ERC20 tokens
/// @dev This library is based on CurrencyLibrary.sol from Uniswap/v4-core and SafeTransferLib.sol from transmissions11/solmate
library TokenHelper {
  /// @notice Additional context for ERC-7751 wrapped error when a native transfer fails
  error NativeTransferFailed();

  /// @notice Additional context for ERC-7751 wrapped error when an ERC20 transfer fails
  error ERC20TransferFailed();

  /// @notice Additional context for ERC-7751 wrapped error when an ERC20 approve fails
  error ERC20ApproveFailed();

  address internal constant NATIVE_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  function isNative(address token) internal pure returns (bool) {
    return token == NATIVE_ADDRESS || token == address(0);
  }

  function safeTransferNative(address to, uint256 amount) internal {
    if (amount == 0) return;

    bool success;
    assembly ('memory-safe') {
      // Transfer the ETH and revert if it fails.
      success := call(gas(), to, amount, 0, 0, 0, 0)
    }
    // revert with NativeTransferFailed, containing the bubbled up error as an argument
    if (!success) {
      CustomRevert.bubbleUpAndRevertWith(to, bytes4(0), NativeTransferFailed.selector);
    }
  }

  function safeTransferERC20(address token, address to, uint256 amount) internal {
    if (amount == 0) return;

    bool success;
    assembly ('memory-safe') {
      // Get a pointer to some free memory.
      let fmp := mload(0x40)

      // Write the abi-encoded calldata into memory, beginning with the function selector.
      mstore(fmp, 0xa9059cbb00000000000000000000000000000000000000000000000000000000)
      mstore(add(fmp, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
      mstore(add(fmp, 36), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

      success := and(
        // Set success to whether the call reverted, if not we check it either
        // returned exactly 1 (can't just be non-zero data), or had no return data.
        or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
        // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
        // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
        // Counterintuitively, this call must be positioned second to the or() call in the
        // surrounding and() call or else returndatasize() will be zero during the computation.
        call(gas(), token, 0, fmp, 68, 0, 32)
      )

      // Now clean the memory we used
      mstore(fmp, 0) // 4 byte `selector` and 28 bytes of `to` were stored here
      mstore(add(fmp, 0x20), 0) // 4 bytes of `to` and 28 bytes of `amount` were stored here
      mstore(add(fmp, 0x40), 0) // 4 bytes of `amount` were stored here
    }
    // revert with ERC20TransferFailed, containing the bubbled up error as an argument
    if (!success) {
      CustomRevert.bubbleUpAndRevertWith(
        token, IERC20.transfer.selector, ERC20TransferFailed.selector
      );
    }
  }

  function safeTransfer(address token, address to, uint256 amount) internal {
    if (isNative(token)) {
      safeTransferNative(to, amount);
    } else {
      safeTransferERC20(token, to, amount);
    }
  }

  function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
    if (amount == 0) return;

    bool success;
    assembly ('memory-safe') {
      // Get a pointer to some free memory.
      let fmp := mload(0x40)

      // Write the abi-encoded calldata into memory, beginning with the function selector.
      mstore(fmp, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
      mstore(add(fmp, 4), and(from, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "from" argument.
      mstore(add(fmp, 36), and(to, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "to" argument.
      mstore(add(fmp, 68), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

      success := and(
        // Set success to whether the call reverted, if not we check it either
        // returned exactly 1 (can't just be non-zero data), or had no return data.
        or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
        // We use 100 because the length of our calldata totals up like so: 4 + 32 * 3.
        // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
        // Counterintuitively, this call must be positioned second to the or() call in the
        // surrounding and() call or else returndatasize() will be zero during the computation.
        call(gas(), token, 0, fmp, 100, 0, 32)
      )

      // Now clean the memory we used
      mstore(fmp, 0) // 4 byte `selector` and 28 bytes of `from` were stored here
      mstore(add(fmp, 0x20), 0) // 4 bytes of `from` and 28 bytes of `to` were stored here
      mstore(add(fmp, 0x40), 0) // 4 bytes of `to` and 28 bytes of `amount` were stored here
      mstore(add(fmp, 0x60), 0) // 4 bytes of `amount` were stored here
    }
    // revert with ERC20TransferFailed, containing the bubbled up error as an argument
    if (!success) {
      CustomRevert.bubbleUpAndRevertWith(
        token, IERC20.transferFrom.selector, ERC20TransferFailed.selector
      );
    }
  }

  function trySafeApprove(address token, address spender, uint256 amount)
    internal
    returns (bool success)
  {
    assembly ('memory-safe') {
      // Get a pointer to some free memory.
      let fmp := mload(0x40)

      // Write the abi-encoded calldata into memory, beginning with the function selector.
      mstore(fmp, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
      mstore(add(fmp, 4), and(spender, 0xffffffffffffffffffffffffffffffffffffffff)) // Append and mask the "spender" argument.
      mstore(add(fmp, 36), amount) // Append the "amount" argument. Masking not required as it's a full 32 byte type.

      success := and(
        // Set success to whether the call reverted, if not we check it either
        // returned exactly 1 (can't just be non-zero data), or had no return data.
        or(and(eq(mload(0), 1), gt(returndatasize(), 31)), iszero(returndatasize())),
        // We use 68 because the length of our calldata totals up like so: 4 + 32 * 2.
        // We use 0 and 32 to copy up to 32 bytes of return data into the scratch space.
        // Counterintuitively, this call must be positioned second to the or() call in the
        // surrounding and() call or else returndatasize() will be zero during the computation.
        call(gas(), token, 0, fmp, 68, 0, 32)
      )

      // Now clean the memory we used
      mstore(fmp, 0) // 4 byte `selector` and 28 bytes of `to` were stored here
      mstore(add(fmp, 0x20), 0) // 4 bytes of `to` and 28 bytes of `amount` were stored here
      mstore(add(fmp, 0x40), 0) // 4 bytes of `amount` were stored here
    }
  }

  function safeApprove(address token, address spender, uint256 amount) internal {
    // revert with ERC20ApproveFailed, containing the bubbled up error as an argument
    if (!trySafeApprove(token, spender, amount)) {
      CustomRevert.bubbleUpAndRevertWith(
        token, IERC20.approve.selector, ERC20ApproveFailed.selector
      );
    }
  }

  function forceApprove(address token, address spender, uint256 amount) internal {
    // meant to be used with tokens that require the approval to be set to zero before setting it to a non-zero value, such as USDT
    if (!trySafeApprove(token, spender, amount)) {
      safeApprove(token, spender, 0);
      safeApprove(token, spender, amount);
    }
  }

  function balanceOf(address token, address account) internal view returns (uint256) {
    if (isNative(token)) {
      return account.balance;
    } else {
      return IERC20(token).balanceOf(account);
    }
  }

  function selfBalance(address token) internal view returns (uint256) {
    if (isNative(token)) {
      return address(this).balance;
    } else {
      return IERC20(token).balanceOf(address(this));
    }
  }
}
