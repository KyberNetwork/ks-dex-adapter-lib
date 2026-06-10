// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/ghost/GhostAdapter.sol';
import 'src/adapters/ghost/ICrossCollateralRouter.sol';

contract GhostAdapterTest is Test {
  using TokenHelper for address;

  GhostAdapter adapter;
  address recipient = makeAddr('recipient');

  // Ethereum
  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address constant USDC_ROUTER = 0xA9C9a8FB36Ce3e5ffBAC3757dA7141262723541F;
  address constant USDT_ROUTER = 0xeB1b48b238E15A62e1858a601B6BfFdf41163AE3;

  string RPC_URL = 'https://ethereum-rpc.publicnode.com';

  function setUp() public {
    vm.createSelectFork(RPC_URL);
    adapter = new GhostAdapter();
  }

  function test_executeGhost(uint256 amount, bool usdcToUsdt) public {
    address sourceRouter = usdcToUsdt ? USDC_ROUTER : USDT_ROUTER;
    address targetRouter = usdcToUsdt ? USDT_ROUTER : USDC_ROUTER;
    address tokenIn = usdcToUsdt ? USDC : USDT;
    address tokenOut = usdcToUsdt ? USDT : USDC;

    amount = bound(amount, 1e6, 100_000_000e6);

    deal(tokenOut, targetRouter, amount * 2);

    uint32 domain = ICrossCollateralRouter(sourceRouter).localDomain();
    bytes32 targetRouterBytes32 = bytes32(uint256(uint160(targetRouter)));
    bytes32 recipientBytes32 = bytes32(uint256(uint160(recipient)));

    Quote[] memory quotes = ICrossCollateralRouter(sourceRouter).quoteTransferRemoteTo(
      domain, recipientBytes32, amount, targetRouterBytes32
    );
    uint256 amountIn = quotes[1].amount;

    deal(tokenIn, address(adapter), amountIn);

    bytes memory data = abi.encode(sourceRouter, targetRouterBytes32, amount);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeGhost(data, amountIn, tokenIn, tokenOut, recipient);

    assertEq(amountUnused, 0);
    assertEq(amountOut, tokenOut.balanceOf(recipient));
    assertGt(amountOut, 0);
  }
}
