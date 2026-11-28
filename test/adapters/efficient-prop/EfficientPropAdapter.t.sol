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
/// The doors and the block come from the environment, and the tests are skipped unless all three
/// are set:
/// - `RPC_1`: an Ethereum endpoint, the variable `foundry.toml`'s `mainnet` reads. An empty value
///   counts as unset, which is what a `pull_request` run raised from a fork sees;
/// - `EFFICIENT_PROP_DOOR`: one listing door's address, or several separated by commas. Mode 1
///   takes one of two entries by the listing (the paid entry where the front names its pool, the
///   allowance entry where it names none), so two doors, one of each kind, cover both;
/// - `EFFICIENT_PROP_BLOCK`: a block in which the listings' maker's update landed. A fork at a
///   block runs in that block's number and time, so the quote and the fill read that update.
contract EfficientPropAdapterTest is Test {
  using TokenHelper for address;

  uint256 constant MODE_DOOR = 0;
  uint256 constant MODE_FRONT = 1;

  EfficientPropAdapter adapter;
  IPropAMMListingDoorTestHooks[] doors;
  address recipient = makeAddr('recipient');

  function setUp() public {
    string memory rpc = vm.envOr('RPC_1', string(''));
    address[] memory ds = vm.envOr('EFFICIENT_PROP_DOOR', ',', new address[](0));
    uint256 blockNumber = vm.envOr('EFFICIENT_PROP_BLOCK', uint256(0));
    if (bytes(rpc).length == 0 || ds.length == 0 || blockNumber == 0) {
      vm.skip(true, 'set RPC_1, EFFICIENT_PROP_DOOR and EFFICIENT_PROP_BLOCK');
      return;
    }
    vm.createSelectFork(rpc, blockNumber);

    for (uint256 i; i < ds.length; ++i) {
      doors.push(IPropAMMListingDoorTestHooks(ds[i]));
    }
    adapter = new EfficientPropAdapter();
  }

  /// @dev Mode 0, both directions: the adapter approves the door and calls its pull entry.
  function test_door(uint256 amountIn, uint256 exponent, bool token0In, uint256 which) public {
    _fill(MODE_DOOR, amountIn, exponent, token0In, which);
  }

  /// @dev Mode 1, both directions: the adapter pays the pool the front names and calls the paid
  /// entry, or approves the front and calls its allowance entry where the front names no pool.
  function test_front(uint256 amountIn, uint256 exponent, bool token0In, uint256 which) public {
    _fill(MODE_FRONT, amountIn, exponent, token0In, which);
  }

  /// @dev With two doors or more set, mode 1's two entries are both under test: the front names
  /// a pool for one listing and none for another.
  function test_front_coversBothEntries() public {
    if (doors.length < 2) {
      vm.skip(true, 'set two doors in EFFICIENT_PROP_DOOR');
      return;
    }
    bool paid;
    bool allowance;
    for (uint256 i; i < doors.length; ++i) {
      address pool = IPropAMMFront(doors[i].FRONT()).payPoolOf(doors[i].LISTING());
      if (pool == address(0)) allowance = true;
      else paid = true;
    }
    assertTrue(paid, 'no door of a listing the front names a pool for');
    assertTrue(allowance, 'no door of a listing the front names no pool for');
  }

  /// @dev Draw a door and a size, quote it at the door, fill it through the adapter in `mode` and
  /// check the fill against the quote. The size is drawn evenly across nine powers of ten around
  /// one whole input token, since a listing fills a narrow band of sizes that an even draw over
  /// the whole range would rarely reach.
  function _fill(uint256 mode, uint256 amountIn, uint256 exponent, bool token0In, uint256 which)
    internal
  {
    IPropAMMListingDoorTestHooks door = doors[bound(which, 0, doors.length - 1)];
    address front = door.FRONT();
    uint24 listing = door.LISTING();
    (address tokenIn, address tokenOut) =
      token0In ? (door.TOKEN0(), door.TOKEN1()) : (door.TOKEN1(), door.TOKEN0());
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
    // An approval is for exactly the input and the venue pulls exactly that, so none is left; the
    // paid entry gives none at all.
    IERC20Metadata input = IERC20Metadata(tokenIn);
    assertEq(input.allowance(address(adapter), address(door)), 0, 'no door allowance left');
    assertEq(input.allowance(address(adapter), front), 0, 'no front allowance left');
    address pool = IPropAMMFront(front).payPoolOf(listing);
    if (pool != address(0)) {
      assertEq(input.allowance(address(adapter), pool), 0, 'the paid pool is never approved');
    }
  }
}
