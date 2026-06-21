// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IMachimaAggregatorRouter.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title MachimaAdapter
/// @notice KyberSwap DEX adapter for Machima/Elixir pools on Base.
///         Routes through MachimaAggregatorRouter which wraps the gated
///         MachimaSwapAdapter with a standard swap interface.
/// @dev Machima pools are a taxed Uniswap V3 fork. The pool-level swap()
///      is gated (NAU), so we route through the aggregator router which
///      is an authorized caller of the underlying adapter. Tax is applied
///      automatically inside the adapter.
contract MachimaAdapter {
    using TokenHelper for address;
    using CalldataDecoder for bytes;

    /// @notice Execute a swap through Machima's aggregator router.
    /// @param data ABI-encoded: (address router, uint256 deadline)
    /// @param amountIn Amount of tokenIn (already in this contract)
    /// @param tokenIn Input token address
    /// @param tokenOut Output token address
    /// @param - Recipient (unused; Kyber's router handles forwarding)
    /// @return amountUnused Any unswapped input (from XMA sell floor partial fills)
    /// @return amountOut Amount of tokenOut received
    function executeMachima(
        bytes calldata data,
        uint256 amountIn,
        address tokenIn,
        address tokenOut,
        address /* recipient */
    ) external payable returns (uint256 amountUnused, uint256 amountOut) {
        (address router, uint256 deadline) = _decodeData(data);

        // Approve the Machima aggregator router to pull tokenIn
        tokenIn.forceApprove(router, amountIn);

        // Execute the swap — tax is applied internally by MachimaSwapAdapter
        amountOut = IMachimaAggregatorRouter(router).swap(
            tokenIn,
            tokenOut,
            amountIn,
            0, // minOut enforced by KyberSwap's routing layer
            address(this), // receive here; Kyber handles forwarding
            deadline
        );

        // Check for residual tokenIn (XMA sell floor partial fills)
        uint256 tokenInRemaining = tokenIn.balanceOf(address(this));
        amountUnused = tokenInRemaining;

        // Output stays in adapter — Kyber's router handles the transfer to recipient
    }

    function _decodeData(bytes calldata data)
        internal
        pure
        returns (address router, uint256 deadline)
    {
        router = data.decodeAddress(0);
        deadline = data.decodeUint256(1);
    }
}
