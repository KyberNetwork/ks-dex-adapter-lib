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

  function test_executeGhost(uint256 amountIn, bool usdcToUsdt) public {
    address sourceRouter = usdcToUsdt ? USDC_ROUTER : USDT_ROUTER;
    address targetRouter = usdcToUsdt ? USDT_ROUTER : USDC_ROUTER;
    address tokenIn = usdcToUsdt ? USDC : USDT;
    address tokenOut = usdcToUsdt ? USDT : USDC;

    amountIn = bound(amountIn, 1, 100_000_000_000e6);

    deal(tokenOut, targetRouter, amountIn * 2);
    deal(tokenIn, address(adapter), amountIn);

    bytes memory data = abi.encode(sourceRouter, targetRouter);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeGhost(data, amountIn, tokenIn, tokenOut, recipient);

    assertLe(amountUnused, 1, 'inverse fee dust exceeds 1 wei');
    assertEq(amountOut, tokenOut.balanceOf(recipient));
    assertGt(amountOut, 0);
  }

  function test_noExternalFee(bool usdcToUsdt) public view {
    address sourceRouter = usdcToUsdt ? USDC_ROUTER : USDT_ROUTER;
    address targetRouter = usdcToUsdt ? USDT_ROUTER : USDC_ROUTER;

    uint32 domain = ICrossCollateralRouter(sourceRouter).localDomain();
    bytes32 targetBytes32 = bytes32(uint256(uint160(targetRouter)));
    bytes32 recipientBytes32 = bytes32(uint256(uint160(recipient)));

    Quote[] memory quotes = ICrossCollateralRouter(sourceRouter)
      .quoteTransferRemoteTo(domain, recipientBytes32, 1_000_000, targetBytes32);

    // quotes[0] = gas (0 for same-domain), quotes[1] = principal + protocolFee,
    // quotes[2] = externalFee. Adapter only inverts the protocol fee, so external
    // fee must be 0 for correctness.
    assertEq(quotes.length, 3, 'unexpected quote length');
    assertEq(quotes[0].amount, 0, 'gas fee should be 0 for same-domain');
    assertEq(quotes[2].amount, 0, 'external fee must be 0');
  }
}
