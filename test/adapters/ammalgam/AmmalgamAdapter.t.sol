// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/ammalgam/AmmalgamAdapter.sol';

contract AmmalgamAdapterTest is Test {
  using TokenHelper for address;

  AmmalgamAdapter adapter;

  address constant USDC_WETH = 0x728fD0A966B993fe518B00122D51e494F99aBd6a;
  address constant USDC_USDT = 0xf53D16Bc876212Ae501cCCc1949d73BB55Be4b0E;
  uint256 constant BLOCK_NUMBER = 25_949_710;

  address[] pools = [USDC_WETH, USDC_USDT];
  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork('mainnet', BLOCK_NUMBER);
    adapter = new AmmalgamAdapter();
  }

  function test_executeAmmalgam(uint256 poolIndex, uint256 amountIn, bool xToY) public {
    poolIndex = bound(poolIndex, 0, pools.length - 1);
    IAmmalgamPair pool = IAmmalgamPair(pools[poolIndex]);

    (address tokenX, address tokenY) = pool.underlyingTokens();
    (uint112 reserveX, uint112 reserveY,) = pool.getReserves();

    address tokenIn = xToY ? tokenX : tokenY;
    address tokenOut = xToY ? tokenY : tokenX;
    uint256 reserveIn = xToY ? reserveX : reserveY;

    amountIn = bound(amountIn, reserveIn / 10_000, reserveIn / 100);
    deal(tokenIn, address(adapter), amountIn);

    uint256 balanceOutBefore = tokenOut.balanceOf(recipient);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeAmmalgam(abi.encode(address(pool)), amountIn, tokenIn, tokenOut, recipient);

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    assertEq(amountOut, tokenOut.balanceOf(recipient) - balanceOutBefore);
    assertEq(tokenIn.balanceOf(address(adapter)), 0);
  }
}
