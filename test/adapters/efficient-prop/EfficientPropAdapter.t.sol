// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol';

import './IPropAMMListingDoorTestHooks.sol';
import 'src/adapters/efficient-prop/EfficientPropAdapter.sol';

/// @notice Fork tests against a listing door on Ethereum: one test per mode, each comparing the
/// adapter's fill against the door's own `quote` on the same state it executes against, never
/// against a tolerance. The door's quote is the front's own for the listing, so it is the oracle
/// of both modes.
///
/// The quote is both the oracle and the feasibility filter. A listing refuses sizes for its own
/// reasons (under its minimum, past its depth, no quote for the block), and which sizes those are
/// is the listing's business, not the adapter's, so a fuzzed size the quote refuses is rejected
/// and redrawn rather than asserted on.
///
/// The door and the block come from the environment, and the tests are skipped unless all three
/// are set:
/// - `RPC_1`: an Ethereum endpoint, the variable `foundry.toml`'s `mainnet` reads. An empty value
///   counts as unset, which is what a `pull_request` run raised from a fork sees;
/// - `EFFICIENT_PROP_DOOR`: the listing door's address;
/// - `EFFICIENT_PROP_BLOCK`: a block in which the listing's maker's update landed. A fork at a
///   block runs in that block's number and time, so the quote and the fill read that update.
contract EfficientPropAdapterTest is Test {
  using TokenHelper for address;

  uint256 constant MODE_DOOR = 0;
  uint256 constant MODE_FRONT = 1;

  EfficientPropAdapter adapter;
  IPropAMMListingDoorTestHooks door;
  address front;
  uint24 listing;
  address token0;
  address token1;
  address recipient = makeAddr('recipient');

  function setUp() public {
    string memory rpc = vm.envOr('RPC_1', string(''));
    address d = vm.envOr('EFFICIENT_PROP_DOOR', address(0));
    uint256 blockNumber = vm.envOr('EFFICIENT_PROP_BLOCK', uint256(0));
    if (bytes(rpc).length == 0 || d == address(0) || blockNumber == 0) {
      vm.skip(true, 'set RPC_1, EFFICIENT_PROP_DOOR and EFFICIENT_PROP_BLOCK');
      return;
    }
    vm.createSelectFork(rpc, blockNumber);

    door = IPropAMMListingDoorTestHooks(d);
    front = door.FRONT();
    listing = door.LISTING();
    token0 = door.TOKEN0();
    token1 = door.TOKEN1();
    adapter = new EfficientPropAdapter();
  }

  /// @dev Mode 0, both directions: the adapter approves the door and calls its pull entry.
  function test_door(uint256 amountIn, uint256 exponent, bool token0In) public {
    _fill(MODE_DOOR, amountIn, exponent, token0In);
  }

  /// @dev Mode 1, both directions: the adapter pays the pool the front names and calls the paid
  /// entry, or approves the front and calls its allowance entry where the front names no pool.
  function test_front(uint256 amountIn, uint256 exponent, bool token0In) public {
    _fill(MODE_FRONT, amountIn, exponent, token0In);
  }

  /// @dev Draw a size, quote it at the door, fill it through the adapter in `mode` and check the
  /// fill against the quote. The size is drawn evenly across nine powers of ten around one whole
  /// input token, since a listing fills a narrow band of sizes that an even draw over the whole
  /// range would rarely reach.
  function _fill(uint256 mode, uint256 amountIn, uint256 exponent, bool token0In) internal {
    (address tokenIn, address tokenOut) = token0In ? (token0, token1) : (token1, token0);
    uint256 decimals = IERC20Metadata(tokenIn).decimals();
    exponent = bound(exponent, decimals > 6 ? decimals - 6 : 0, decimals + 2);
    amountIn = bound(amountIn, 10 ** exponent, 10 ** (exponent + 1) - 1);

    uint256 expectedOut;
    try door.quote(tokenIn, tokenOut, amountIn) returns (uint256 out) {
      expectedOut = out;
    } catch {
      // The listing refuses this size, so there is no fill for the adapter to reproduce. Reject the
      // seed rather than returning: a return would count toward the run budget and pass, so a
      // state where every drawn size reverts would leave the adapter unexercised and green.
      vm.assume(false);
    }

    deal(tokenIn, address(adapter), amountIn);
    uint256 recipientBefore = tokenOut.balanceOf(recipient);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeEfficientProp(
      abi.encode(address(door), front, uint256(listing), mode),
      amountIn,
      tokenIn,
      tokenOut,
      recipient
    );

    assertGt(amountOut, 0);
    assertEq(amountOut, expectedOut, 'fill output is the quote');
    assertEq(amountUnused, 0, 'a fill takes the whole input');
    assertEq(tokenIn.balanceOf(address(adapter)), 0, 'whole input spent');
    assertEq(tokenOut.balanceOf(recipient) - recipientBefore, amountOut, 'paid to recipient');
  }
}
