// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol';

import 'src/adapters/efficient-prop/EfficientPropAdapter.sol';

import './IPropAMMListingDoorTestHooks.sol';

/// @notice Base fork test against a listing door and its front, both directions of the listing's
/// pair through each fill mode (0 the door, 1 the front), each fill compared with the door's own
/// `quote` on the state it executes against, never against a tolerance.
///
/// The door and the block come from the environment, and the test is skipped unless both of these
/// are set:
/// - `RPC_8453`: a Base endpoint, the variable `foundry.toml`'s `base_mainnet` reads;
/// - `EFFICIENT_PROP_DOOR`: the listing door's address.
/// `EFFICIENT_PROP_BLOCK` pins a block (default: the endpoint's latest). A listing quotes only
/// while its desk's last post is fresh, so the block should be a few seconds after a desk post; at
/// a block where the post has expired the door fills no size and the test fails.
///
/// The quote is both the oracle and the feasibility filter. A listing refuses sizes for its own
/// reasons (under its minimum, past its depth, no fresh price), so the test walks a ladder of
/// sizes in each direction, fills every size the door quotes from the same state, and needs at
/// least one in each direction. The test runs at gas price 0, so the quote and the fill both see a
/// tip of 0: a pass does not show that a price source fills a real transaction at its quote. Forge
/// reads `block.basefee` differently in a view call and in a state-changing call, so tip behaviour
/// is not tested here.
contract EfficientPropAdapterForkTest is Test {
  using TokenHelper for address;

  EfficientPropAdapter adapter;
  IPropAMMListingDoorTestHooks door;
  address front;
  uint24 listing;
  address token0;
  address token1;
  address recipient = makeAddr('recipient');

  function setUp() public {
    string memory rpc = vm.envOr('RPC_8453', string(''));
    address d = vm.envOr('EFFICIENT_PROP_DOOR', address(0));
    if (bytes(rpc).length == 0 || d == address(0)) {
      vm.skip(true, 'set RPC_8453 and EFFICIENT_PROP_DOOR to run against a listing door');
      return;
    }
    uint256 blockNumber = vm.envOr('EFFICIENT_PROP_BLOCK', uint256(0));
    if (blockNumber == 0) vm.createSelectFork(rpc);
    else vm.createSelectFork(rpc, blockNumber);

    assertEq(block.chainid, 8453, 'a Base endpoint');
    door = IPropAMMListingDoorTestHooks(d);
    front = door.FRONT();
    listing = door.LISTING();
    token0 = door.TOKEN0();
    token1 = door.TOKEN1();
    adapter = new EfficientPropAdapter();
  }

  function test_door_token0ForToken1() public {
    _ladder(token0, token1, 0);
  }

  function test_door_token1ForToken0() public {
    _ladder(token1, token0, 0);
  }

  function test_front_token0ForToken1() public {
    _ladder(token0, token1, 1);
  }

  function test_front_token1ForToken0() public {
    _ladder(token1, token0, 1);
  }

  /// @dev Sizes from 10^(decimals - 6) to 10^(decimals + 6) of the input token, one per power of
  ///      ten. Every size the door quotes is filled from the same state and must pay the quote.
  function _ladder(address tokenIn, address tokenOut, uint256 mode) internal {
    uint256 dec = IERC20Metadata(tokenIn).decimals();
    uint256 lo = dec > 6 ? dec - 6 : 0;
    uint256 filled;
    for (uint256 e = lo; e <= dec + 6; ++e) {
      uint256 amountIn = 10 ** e;
      uint256 expected;
      try door.quote(tokenIn, tokenOut, amountIn) returns (uint256 q) {
        expected = q;
      } catch {
        continue; // the listing does not fill this size now
      }
      uint256 snap = vm.snapshotState();
      uint256 amountOut = _fill(amountIn, tokenIn, tokenOut, mode);
      assertEq(amountOut, expected, 'fill pays the quote');
      emit log_named_uint('filled, size', amountIn);
      vm.revertToState(snap);
      ++filled;
    }
    assertGt(filled, 0, 'the door filled no size in this direction');
  }

  /// @dev Fund the adapter, run the hop, and check what every fill shares: the recipient's balance,
  ///      which is not zero before the fill, rises by exactly `amountOut`, the whole input leaves
  ///      the adapter, nothing is unused and no approval is left on the door or the front.
  function _fill(uint256 amountIn, address tokenIn, address tokenOut, uint256 mode)
    internal
    returns (uint256 amountOut)
  {
    deal(tokenIn, address(adapter), amountIn);
    deal(tokenOut, recipient, 7 * 10 ** IERC20Metadata(tokenOut).decimals());
    uint256 recipientBefore = tokenOut.balanceOf(recipient);

    uint256 amountUnused;
    (amountUnused, amountOut) = adapter.executeEfficientProp(
      abi.encode(address(door), front, uint256(listing), mode),
      amountIn,
      tokenIn,
      tokenOut,
      recipient
    );

    assertEq(amountUnused, 0, 'nothing unused');
    assertEq(
      tokenOut.balanceOf(recipient) - recipientBefore, amountOut, 'amountOut is what was paid'
    );
    assertEq(tokenIn.balanceOf(address(adapter)), 0, 'whole input spent');
    assertEq(IERC20(tokenIn).allowance(address(adapter), address(door)), 0, 'no door approval');
    assertEq(IERC20(tokenIn).allowance(address(adapter), front), 0, 'no front approval');
  }
}
