// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IMachimaAggregatorRouter {
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut);
}
