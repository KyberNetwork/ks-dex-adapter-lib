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
  function validUntil(address base) external view returns (uint64);
  function pair(address base) external view returns (Pair memory);
}

contract SpirePropAdapterTest is Test {
  using TokenHelper for address;
  address constant ENTRYPOINT = 0x98c1D9E102Eb2806D902b13186BDc7892aC4fFBa;
  address constant CURVE = 0x604d9b9eB1e1571C78661a6C1088427EC9c8c6E5;
  address constant CUSTODY = 0xAaC48FEB93c5C97E0fb3c7C57E1633922A4ACDa3;
  address constant WETH = 0x4200000000000000000000000000000000000006;
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
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
    _trade(amountIn, buyBase);
  }

  function _trade(uint256 amountIn, bool buyBase) internal {
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

  /// @dev A second fill consumes the updated cursor, not a fresh origin quote.
  function test_repeatedSwapConsumesCursor() public {
    uint256 before = ISpireCurveView(CURVE).pair(WETH).ask.filled;
    _trade(12.5e6, true);
    uint256 first = ISpireCurveView(CURVE).pair(WETH).ask.filled;
    _trade(12.5e6, true);
    assertGt(first, before);
    assertGt(ISpireCurveView(CURVE).pair(WETH).ask.filled, first);
  }

  /// @dev Curve expiry reverts the complete trade and preserves adapter funds and fill sequence.
  function test_expiredCurveRollsBack() public {
    deal(USDC, address(adapter), 25e6);
    uint64 fillSeq = ISpireCurveView(CURVE).pair(WETH).fillSeq;
    vm.warp(uint256(ISpireCurveView(CURVE).validUntil(WETH)) + 1);
    vm.expectRevert(bytes4(keccak256('CurveStale()')));
    adapter.executeSpireProp(abi.encode(ENTRYPOINT, WETH), 25e6, USDC, WETH, recipient);
    assertEq(USDC.balanceOf(address(adapter)), 25e6);
    assertEq(WETH.balanceOf(recipient), 0);
    assertEq(ISpireCurveView(CURVE).pair(WETH).fillSeq, fillSeq);
  }

  /// @dev A quote does not bypass unavailable output custody, and the input transfer rolls back.
  function test_unavailableCustodyRollsBack() public {
    deal(WETH, CUSTODY, 0);
    deal(USDC, address(adapter), 25e6);
    uint64 fillSeq = ISpireCurveView(CURVE).pair(WETH).fillSeq;
    uint256 custodyIn = USDC.balanceOf(CUSTODY);
    vm.expectPartialRevert(bytes4(keccak256('InsufficientLiquidity(uint256,uint256)')));
    adapter.executeSpireProp(abi.encode(ENTRYPOINT, WETH), 25e6, USDC, WETH, recipient);
    assertEq(USDC.balanceOf(address(adapter)), 25e6);
    assertEq(USDC.balanceOf(CUSTODY), custodyIn);
    assertEq(WETH.balanceOf(recipient), 0);
    assertEq(ISpireCurveView(CURVE).pair(WETH).fillSeq, fillSeq);
  }

  /// @dev Spire rejects an input token outside the pair before transferring the prepaid input.
  function test_unknownTokenInPreservesInput() public {
    deal(CBBTC, address(adapter), 1e8);
    uint64 fillSeq = ISpireCurveView(CURVE).pair(WETH).fillSeq;
    vm.expectRevert(bytes4(keccak256('UnknownToken()')));
    adapter.executeSpireProp(abi.encode(ENTRYPOINT, WETH), 1e8, CBBTC, USDC, recipient);
    assertEq(CBBTC.balanceOf(address(adapter)), 1e8);
    assertEq(ISpireCurveView(CURVE).pair(WETH).fillSeq, fillSeq);
  }

  /// @dev Spire rejects an unlisted base before transferring the prepaid input.
  function test_unlistedBasePreservesInput() public {
    deal(USDC, address(adapter), 25e6);
    vm.expectRevert(bytes4(keccak256('UnknownToken()')));
    adapter.executeSpireProp(
      abi.encode(ENTRYPOINT, makeAddr('unlisted base')), 25e6, USDC, WETH, recipient
    );
    assertEq(USDC.balanceOf(address(adapter)), 25e6);
  }

  /// @dev Spire rejects both native sentinels as input, so the adapter needs no native check.
  function test_nativeSentinelsRejected() public {
    address[2] memory nativeTokens = [address(0), TokenHelper.NATIVE_ADDRESS];
    for (uint256 i; i < nativeTokens.length; ++i) {
      vm.expectRevert(bytes4(keccak256('UnknownToken()')));
      adapter.executeSpireProp(abi.encode(ENTRYPOINT, WETH), 1, nativeTokens[i], USDC, recipient);
    }
  }

  /// @dev Zero input is rejected by the protocol without consuming a fill sequence.
  function test_zeroInput() public {
    uint64 fillSeq = ISpireCurveView(CURVE).pair(WETH).fillSeq;
    vm.expectRevert(bytes4(keccak256('ZeroAmount()')));
    adapter.executeSpireProp(abi.encode(ENTRYPOINT, WETH), 0, USDC, WETH, recipient);
    assertEq(ISpireCurveView(CURVE).pair(WETH).fillSeq, fillSeq);
    assertEq(WETH.balanceOf(recipient), 0);
  }
}
