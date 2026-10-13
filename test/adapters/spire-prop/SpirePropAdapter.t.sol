// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'src/adapters/spire-prop/SpirePropAdapter.sol';

interface ISpireCurveView {
  struct Side {
    int16 spreadBps;
    uint16 depthBps;
    uint256 filled;
    uint8 knotCount;
  }

  struct Pair {
    uint64 seq;
    uint64 fillSeq;
    uint64 lastUpdateAt;
    uint80 mid;
    uint256 qUnit;
    Side ask;
    Side bid;
  }
  function quote(address base, address tokenIn, uint256 amountIn) external view returns (uint256);
  function pair(address base) external view returns (Pair memory);
}

contract SpirePropAdapterTest is Test {
  using TokenHelper for address;
  address constant ENTRYPOINT = 0x98c1D9E102Eb2806D902b13186BDc7892aC4fFBa;
  address constant CURVE = 0x604d9b9eB1e1571C78661a6C1088427EC9c8c6E5;
  address constant CUSTODY = 0xAaC48FEB93c5C97E0fb3c7C57E1633922A4ACDa3;
  address constant WETH = 0x4200000000000000000000000000000000000006;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint256 constant FORK_BLOCK = 50_979_793;
  SpirePropAdapter adapter;
  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork('base_mainnet', FORK_BLOCK);
    adapter = new SpirePropAdapter();
  }

  /// @dev Both directions match the actual curve and transfer exact input/output through custody.
  function test_exactInputBothDirections(uint256 amountIn, bool buyBase) public {
    amountIn = buyBase ? bound(amountIn, 1e6, 500e6) : bound(amountIn, 1e15, 0.1 ether);
    address tokenIn = buyBase ? USDC : WETH;
    address tokenOut = buyBase ? WETH : USDC;
    uint256 expected = ISpireCurveView(CURVE).quote(WETH, tokenIn, amountIn);
    assertGt(expected, 0);
    uint256 custodyIn = tokenIn.balanceOf(CUSTODY);
    uint256 custodyOut = tokenOut.balanceOf(CUSTODY);
    uint256 recipientBefore = tokenOut.balanceOf(recipient);
    uint64 fillSeq = ISpireCurveView(CURVE).pair(WETH).fillSeq;
    deal(tokenIn, address(adapter), amountIn);
    (uint256 unused, uint256 amountOut) =
      adapter.executeSpireProp(abi.encode(ENTRYPOINT, WETH), amountIn, tokenIn, tokenOut, recipient);
    assertEq(unused, 0);
    assertEq(amountOut, expected);
    assertEq(tokenIn.balanceOf(address(adapter)), 0);
    assertEq(IERC20(tokenIn).allowance(address(adapter), ENTRYPOINT), 0);
    assertEq(tokenOut.balanceOf(recipient) - recipientBefore, expected);
    assertEq(tokenIn.balanceOf(CUSTODY), custodyIn + amountIn);
    assertEq(tokenOut.balanceOf(CUSTODY), custodyOut - expected);
    assertEq(ISpireCurveView(CURVE).pair(WETH).fillSeq, fillSeq + 1);
  }
}
