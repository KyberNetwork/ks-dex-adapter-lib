// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/uniswap-v2/UniswapV2Adapter.sol';

contract UniswapV2AdapterTest is Test {
  using TokenHelper for address;
  UniswapV2Adapter adapter;

  address WETH_FLOKI = 0xca7c2771D248dCBe09EABE0CE57A62e18dA178c0;
  address WETH_USDT = 0x0d4a11d5EEaaC28EC3F61d100daF4d40471f1852;
  address[] pools = [WETH_FLOKI, WETH_USDT];

  address recipient = makeAddr('recipient');

  string RPC_URL = 'https://1rpc.io/eth';
  uint256 BLOCK_NUMBER = 24_425_629;

  function setUp() public {
    vm.createSelectFork(RPC_URL, BLOCK_NUMBER);

    adapter = new UniswapV2Adapter();
  }

  function test_executeUniswapV2(uint256 poolIndex, uint256 amountIn, bool zeroForOne) public {
    poolIndex = bound(poolIndex, 0, 1);

    address pool = pools[poolIndex];

    address tokenIn;
    address tokenOut;
    if (zeroForOne) {
      tokenIn = IUniswapV2Pair(pool).token0();
      tokenOut = IUniswapV2Pair(pool).token1();
    } else {
      tokenIn = IUniswapV2Pair(pool).token1();
      tokenOut = IUniswapV2Pair(pool).token0();
    }

    amountIn = bound(amountIn, tokenIn.balanceOf(pool) / 10_000, tokenIn.balanceOf(pool) / 10);
    deal(tokenIn, address(adapter), amountIn);

    bytes memory data = abi.encode(pool, 3, 1000);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeUniswapV2(data, amountIn, tokenIn, tokenOut, recipient);

    assertEq(amountUnused, tokenIn.balanceOf(address(adapter)));
    assertEq(amountOut, tokenOut.balanceOf(recipient));
  }
}
