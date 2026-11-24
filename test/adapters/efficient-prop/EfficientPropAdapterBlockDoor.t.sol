// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import {EfficientPropMockPool, EfficientPropTestToken} from './EfficientPropAdapter.t.sol';
import 'src/adapters/efficient-prop/EfficientPropAdapter.sol';
import 'src/adapters/efficient-prop/IPropAMMBlockDoor.sol';

/// @dev A look-alike of a block door over one pair and its pool, with the real door's rules for
///      the deadline and the payment: `swap` reads its last argument as a block number (0 and
///      `type(uint256).max` name none; any other must be this block or one at most
///      `MAX_BLOCKS_AHEAD` on), refuses where the door holds less than `amountIn`, sends exactly
///      `amountIn` on to the pool and has the pool pay the recipient at a fixed rate. `setRefuse`
///      makes every fill revert after the checks. Records the last fill's terms.
contract EfficientPropMockBlockDoor is IPropAMMBlockDoor {
  error BlockPassed(uint256 maxBlockNumber, uint256 blockNumber);
  error BlockTooFar(uint256 maxBlockNumber, uint256 blockNumber);
  error ShortPush(uint256 held, uint256 amountIn);
  error Refused(uint256 held);

  uint256 public constant MAX_BLOCKS_AHEAD = 64;

  address immutable TOKEN0;
  address immutable POOL;
  uint256 immutable RATE;
  bool refuse;
  bytes public lastTerms;

  constructor(address token0, address pool, uint256 rate) {
    (TOKEN0, POOL, RATE) = (token0, pool, rate);
  }

  function setRefuse(bool on) external {
    refuse = on;
  }

  function quote(address tokenIn, uint256 amountIn) public view returns (uint256) {
    return tokenIn == TOKEN0 ? amountIn * RATE / 1e18 : amountIn * 1e18 / RATE;
  }

  function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 maxBlockNumber
  ) external returns (uint256 amountOut) {
    if (maxBlockNumber != 0 && maxBlockNumber != type(uint256).max) {
      if (maxBlockNumber < block.number) revert BlockPassed(maxBlockNumber, block.number);
      if (maxBlockNumber > block.number + MAX_BLOCKS_AHEAD) {
        revert BlockTooFar(maxBlockNumber, block.number);
      }
    }
    uint256 held = IERC20(tokenIn).balanceOf(address(this));
    if (held < amountIn) revert ShortPush(held, amountIn);
    if (refuse) revert Refused(held);
    IERC20(tokenIn).transfer(POOL, amountIn);
    amountOut = quote(tokenIn, amountIn);
    require(amountOut >= minAmountOut, 'slippage');
    lastTerms = abi.encode(minAmountOut, maxBlockNumber, recipient);
    EfficientPropMockPool(POOL).pay(tokenOut, recipient, amountOut);
  }
}

/// @notice Unit tests for EfficientPropAdapter's mode 2, a block door (push payment, the last
/// argument a block number), against a mock with the real door's deadline and payment rules:
/// - both directions fill at the door's quote, with this block as the last block, the input pushed
///   and swapped in one frame with no call between, nothing left at the door and no approval
///   given (`test_blockDoor_bothDirections`, `test_blockDoor_oneFrame`);
/// - a unix second as the deadline would be refused by the door, which this mock proves it reads
///   as a block (`test_mockRefusesAUnixSecond`);
/// - a refusal after the push undoes the push (`test_blockDoor_refusalUndoesPush`).
contract EfficientPropAdapterBlockDoorTest is Test {
  EfficientPropAdapter adapter;
  EfficientPropTestToken token0;
  EfficientPropTestToken token1;
  EfficientPropMockPool pool;
  EfficientPropMockBlockDoor door;

  address recipient = makeAddr('recipient');

  uint256 constant RATE = 600e18; // 1 token0 = 600 token1
  uint256 constant HELD = 5; // input the adapter holds beside `amountIn`, which a fill leaves

  function setUp() public {
    vm.roll(70_000_000); // a block number no unix second passes for
    vm.warp(1_795_000_000);
    adapter = new EfficientPropAdapter();
    EfficientPropTestToken a = new EfficientPropTestToken();
    EfficientPropTestToken b = new EfficientPropTestToken();
    (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
    pool = new EfficientPropMockPool();
    token0.mint(address(pool), 1e12 ether);
    token1.mint(address(pool), 1e15 ether);
    door = new EfficientPropMockBlockDoor(address(token0), address(pool), RATE);
  }

  function test_blockDoor_bothDirections(uint256 amountIn, bool zeroForOne) public {
    (EfficientPropTestToken tIn, EfficientPropTestToken tOut) =
      zeroForOne ? (token0, token1) : (token1, token0);
    amountIn = zeroForOne ? bound(amountIn, 1, 1e9 ether) : bound(amountIn, 600, 1e12 ether);
    tIn.mint(address(adapter), amountIn + HELD);
    uint256 poolBefore = tIn.balanceOf(address(pool));
    uint256 expected = door.quote(address(tIn), amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEfficientProp(_data(), amountIn, address(tIn), address(tOut), recipient);

    assertEq(door.lastTerms(), abi.encode(1, block.number, recipient), 'venue terms');
    assertEq(amountUnused, 0, 'nothing unused');
    assertEq(amountOut, expected, 'output is the quote');
    assertEq(tOut.balanceOf(recipient), amountOut, 'amountOut was paid');
    assertEq(tIn.balanceOf(address(adapter)), HELD, 'amountIn spent, no more');
    assertEq(tIn.balanceOf(address(door)), 0, 'nothing left at the door');
    assertEq(tIn.balanceOf(address(pool)) - poolBefore, amountIn, 'pool took the input');
    assertEq(tIn.allowance(address(adapter), address(door)), 0, 'no approval on the door');
  }

  /// @dev The push and the swap are the adapter's only two calls out, in that order, with nothing
  ///      between: the transfer to the door, then the door's `swap`.
  function test_blockDoor_oneFrame(bool zeroForOne) public {
    (EfficientPropTestToken tIn, EfficientPropTestToken tOut) =
      zeroForOne ? (token0, token1) : (token1, token0);
    uint256 amountIn = 1 ether;
    tIn.mint(address(adapter), amountIn);
    vm.expectCall(address(tIn), abi.encodeCall(IERC20.transfer, (address(door), amountIn)), 1);
    vm.expectCall(
      address(door),
      abi.encodeCall(
        IPropAMMBlockDoor.swap, (address(tIn), address(tOut), amountIn, 1, recipient, block.number)
      ),
      1
    );
    vm.recordLogs();
    adapter.executeEfficientProp(_data(), amountIn, address(tIn), address(tOut), recipient);
    // the input's first two transfers: the adapter's push, then the door's send to the pool
    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 n;
    address[2] memory to;
    for (uint256 i = 0; i < logs.length && n < 2; i++) {
      if (logs[i].emitter == address(tIn)) to[n++] = address(uint160(uint256(logs[i].topics[2])));
    }
    assertEq(to[0], address(door), 'the push comes first');
    assertEq(to[1], address(pool), 'then the door sends it on');
  }

  function test_mockRefusesAUnixSecond() public {
    token0.mint(address(door), 1 ether);
    vm.expectRevert(
      abi.encodeWithSelector(
        EfficientPropMockBlockDoor.BlockTooFar.selector, block.timestamp, block.number
      )
    );
    door.swap(address(token0), address(token1), 1 ether, 1, recipient, block.timestamp);
  }

  function test_blockDoor_refusalUndoesPush(uint256 amountIn, bool zeroForOne) public {
    (EfficientPropTestToken tIn, EfficientPropTestToken tOut) =
      zeroForOne ? (token0, token1) : (token1, token0);
    amountIn = bound(amountIn, 600, 1e9 ether);
    tIn.mint(address(adapter), amountIn);
    door.setRefuse(true);
    vm.expectRevert(abi.encodeWithSelector(EfficientPropMockBlockDoor.Refused.selector, amountIn));
    adapter.executeEfficientProp(_data(), amountIn, address(tIn), address(tOut), recipient);
    assertEq(tIn.balanceOf(address(adapter)), amountIn, 'the push is undone');
    assertEq(tIn.balanceOf(address(door)), 0, 'nothing at the door');
  }

  function _data() internal view returns (bytes memory) {
    return abi.encode(address(door), address(0), uint256(0), uint256(2));
  }
}
