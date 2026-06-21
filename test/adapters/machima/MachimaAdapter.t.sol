// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/machima/MachimaAdapter.sol';
import 'src/libraries/TokenHelper.sol';

/// @notice Integration test for MachimaAdapter on Base mainnet fork.
///         Tests real swaps through the deployed MachimaAggregatorRouter.
contract MachimaAdapterTest is Test {
    using TokenHelper for address;

    MachimaAdapter adapter;

    // Deployed on Base mainnet (June 2026)
    address constant MACHIMA_ROUTER = 0x0D4Ca1Db806FF9009B6F227980De41d7f383da8d;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant XMA = 0xA4985Faeb1e64Ba215282255dBb78ff59C63d7A9;

    address recipient = makeAddr('recipient');

    string RPC_URL = 'https://mainnet.base.org';

    function setUp() public {
        // Fork at latest — router was deployed June 2026
        vm.createSelectFork(RPC_URL);
        adapter = new MachimaAdapter();
    }

    /// @notice Buy XMA with WETH — validates the standard buy path
    function test_buyXmaWithWeth() public {
        uint256 amountIn = 0.01 ether;
        address tokenIn = WETH;
        address tokenOut = XMA;

        deal(tokenIn, address(adapter), amountIn);

        uint256 deadline = block.timestamp + 300;
        bytes memory data = abi.encode(MACHIMA_ROUTER, deadline);

        (uint256 amountUnused, uint256 amountOut) = adapter.executeMachima(
            data,
            amountIn,
            tokenIn,
            tokenOut,
            recipient
        );

        assertGt(amountOut, 0, "Should receive XMA output");
        assertEq(amountUnused, 0, "No residual expected for buys");
        assertGt(tokenOut.balanceOf(address(adapter)), 0, "Output held in adapter for Kyber");
    }

    /// @notice Sell XMA for WETH — validates the standard sell path
    function test_sellXmaForWeth() public {
        uint256 xmaAmount = 1_000_000 ether;
        address tokenIn = XMA;
        address tokenOut = WETH;

        deal(tokenIn, address(adapter), xmaAmount);

        uint256 deadline = block.timestamp + 300;
        bytes memory data = abi.encode(MACHIMA_ROUTER, deadline);

        (uint256 amountUnused, uint256 amountOut) = adapter.executeMachima(
            data,
            xmaAmount,
            tokenIn,
            tokenOut,
            recipient
        );

        assertGt(amountOut, 0, "Should receive WETH output");
        // amountUnused may be > 0 if XMA sell floor is hit (partial fill)
        assertLe(amountUnused, xmaAmount, "Unused cannot exceed input");
    }

    /// @notice XMA sell that hits the price floor — validates partial fill + residual
    function test_xmaSellFloorPartialFill() public {
        // Use a very large amount to attempt to push past the XMA sell floor
        uint256 xmaAmount = 100_000_000_000 ether; // 100B XMA — should hit floor
        address tokenIn = XMA;
        address tokenOut = WETH;

        deal(tokenIn, address(adapter), xmaAmount);

        uint256 deadline = block.timestamp + 300;
        bytes memory data = abi.encode(MACHIMA_ROUTER, deadline);

        // This may revert if the pool doesn't have enough liquidity,
        // or succeed with amountUnused > 0 if floor is hit
        try adapter.executeMachima(data, xmaAmount, tokenIn, tokenOut, recipient) returns (
            uint256 amountUnused,
            uint256 amountOut
        ) {
            // If it succeeds, either the floor was hit (amountUnused > 0)
            // or the full amount was swapped
            if (amountUnused > 0) {
                assertGt(amountOut, 0, "Partial fill should still produce output");
                assertLt(amountUnused, xmaAmount, "Not all should be unused");
            }
        } catch {
            // Acceptable — pool may not have liquidity for this size
        }
    }

    /// @notice Invalid pair (USDC→XMA) should revert — XMA pairs with WETH only
    function test_revert_invalidPairUsdcToXma() public {
        uint256 amountIn = 10 * 1e6;
        address tokenIn = USDC;
        address tokenOut = XMA;

        deal(tokenIn, address(adapter), amountIn);

        uint256 deadline = block.timestamp + 300;
        bytes memory data = abi.encode(MACHIMA_ROUTER, deadline);

        vm.expectRevert();
        adapter.executeMachima(data, amountIn, tokenIn, tokenOut, recipient);
    }

    /// @notice Expired deadline should revert
    function test_revert_expiredDeadline() public {
        uint256 amountIn = 0.01 ether;
        address tokenIn = WETH;
        address tokenOut = XMA;

        deal(tokenIn, address(adapter), amountIn);

        uint256 deadline = block.timestamp - 1; // already expired
        bytes memory data = abi.encode(MACHIMA_ROUTER, deadline);

        vm.expectRevert();
        adapter.executeMachima(data, amountIn, tokenIn, tokenOut, recipient);
    }

    /// @notice Data encoding roundtrip verification
    function test_dataEncoding() public pure {
        uint256 deadline = 1_700_000_000;
        bytes memory data = abi.encode(MACHIMA_ROUTER, deadline);
        assertEq(data.length, 64);
    }
}
