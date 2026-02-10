// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import './TickMath.sol';
import 'src/adapters/uniswap-v3/UniswapV3Adapter.sol';

contract UniswapV3AdapterTest is Test {
  using TokenHelper for address;
  UniswapV3Adapter adapter;

  address USDC_WETH = 0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640;
  address WBTC_CBBTC = 0xe8f7c89C5eFa061e340f2d2F206EC78FD8f7e124;
  address[] pools = [USDC_WETH, WBTC_CBBTC];

  address recipient = makeAddr('recipient');

  string RPC_URL = 'https://1rpc.io/eth';
  uint256 BLOCK_NUMBER = 24_425_629;

  function setUp() public {
    vm.createSelectFork(RPC_URL, BLOCK_NUMBER);

    adapter = new UniswapV3Adapter();
  }

  function test_executeUniswapV3(
    uint256 poolIndex,
    uint256 amountIn,
    bool zeroForOne,
    uint256 sqrtPriceLimitX96
  ) public {
    poolIndex = bound(poolIndex, 0, 1);

    address pool = pools[poolIndex];

    address tokenIn;
    address tokenOut;
    if (zeroForOne) {
      tokenIn = IUniswapV3Pool(pool).token0();
      tokenOut = IUniswapV3Pool(pool).token1();
    } else {
      tokenIn = IUniswapV3Pool(pool).token1();
      tokenOut = IUniswapV3Pool(pool).token0();
    }

    amountIn = bound(amountIn, tokenIn.balanceOf(pool) / 10_000, tokenIn.balanceOf(pool) / 10);
    deal(tokenIn, address(adapter), amountIn);

    (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
    if (zeroForOne) {
      sqrtPriceLimitX96 = bound(
        sqrtPriceLimitX96,
        TickMath.getSqrtRatioAtTick(tick - 50),
        TickMath.getSqrtRatioAtTick(tick - 1)
      );
    } else {
      sqrtPriceLimitX96 = bound(
        sqrtPriceLimitX96,
        TickMath.getSqrtRatioAtTick(tick + 1),
        TickMath.getSqrtRatioAtTick(tick + 50)
      );
    }

    bytes memory data = abi.encode(pool, sqrtPriceLimitX96);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeUniswapV3(data, amountIn, tokenIn, tokenOut, recipient);

    assertEq(amountUnused, tokenIn.balanceOf(address(adapter)));
    assertEq(amountOut, tokenOut.balanceOf(recipient));
  }
}
