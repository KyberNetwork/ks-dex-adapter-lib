// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/interfaces/IERC20Metadata.sol';

import 'src/adapters/efficient-prop/EfficientPropAdapter.sol';

import './IPropAMMListingDoorTestHooks.sol';

/// @notice Ethereum fork test of both modes on a builder chain: mode 0, the listing's door, and mode
/// 1, the front's own entries (the paid entry where the front names the listing's pool, the named
/// entry on a listing with a credit mode). There a listing fills only in a block in which its quote
/// contract's update landed ahead of the fill; in any other block the front refuses the fill with
/// `NoWord()`, except in the block right after an entry that set the carry bit: there a fill that
/// finds the quote's price update past the listing's price age reverts `StalePull()`, one that finds
/// the quote's life ended reverts `AnchorExpired()`, and a fill inside both limits fills at the
/// carried quote.
/// Both directions of the listing's pair, in each mode:
/// - in a block with the update, every size the door quotes from that state fills at the quote in
///   either mode (the door's quote is the front's own for the listing), `amountOut` is the
///   recipient's balance delta, and the listing's quote contract logs one `Swapped` for the fill,
///   which is what a builder matches the fill by, naming the front's caller its sender: the door in
///   mode 0, the adapter in mode 1. The door itself logs none on a builder chain;
/// - in a block without it, the door's quote reverts `NoFill()` for every size it quoted in the
///   update's block, and the hop for each of those sizes reverts the whole call with the front's
///   `NoWord()`. The revert itself undoes the input's move and the approval, so the test checks
///   nothing after it.
///
/// The test is skipped unless these are set:
/// - `RPC_1`: an Ethereum endpoint, the variable `foundry.toml`'s `mainnet` reads, that serves the
///   state at both blocks;
/// - `EFFICIENT_PROP_ETH_DOOR`: the listing door's address;
/// - `EFFICIENT_PROP_ETH_BLOCK`: a block in which the listing's update landed.
/// `EFFICIENT_PROP_ETH_NO_ENTRY_BLOCK` names a block in which it did not and that is not the block
/// right after an entry that set the carry bit; the two tests of that block are skipped without it.
///
/// A fork at a block runs in that block's number and time, so the door's quote and the fill read
/// the quote the block's update wrote. The test runs at gas price 0, so the quote and the fill both
/// see a tip of 0: a pass does not show that a price source fills a real transaction at its quote.
contract EfficientPropAdapterEthForkTest is Test {
  using TokenHelper for address;

  /// @dev The front's refusal of a fill in a block where the listing's quote contract holds no
  ///      quote for the block.
  error NoWord();

  /// @dev The door's refusal to quote a size it cannot fill now.
  error NoFill();

  /// @dev A fill's log, the one a builder matches a route's fill to its listing by. On a builder
  ///      chain the listing's quote contract logs it, with the front's caller, the door, as sender.
  event Swapped(
    address indexed sender,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 amountIn,
    uint256 amountOut,
    address recipient
  );

  EfficientPropAdapter adapter;
  IPropAMMListingDoorTestHooks door;
  string rpc;
  uint256 noEntryBlock;
  address front;
  uint24 listing;
  address token0;
  address token1;
  /// @dev The listing's quote contract: its desk's, which the front names (`deskCellOf`).
  address quoteContract;
  address recipient = makeAddr('recipient');

  function setUp() public {
    rpc = vm.envOr('RPC_1', string(''));
    address d = vm.envOr('EFFICIENT_PROP_ETH_DOOR', address(0));
    uint256 entryBlock = vm.envOr('EFFICIENT_PROP_ETH_BLOCK', uint256(0));
    if (bytes(rpc).length == 0 || d == address(0) || entryBlock == 0) {
      vm.skip(
        true,
        'set RPC_1, EFFICIENT_PROP_ETH_DOOR and EFFICIENT_PROP_ETH_BLOCK to run against a listing door'
      );
      return;
    }
    noEntryBlock = vm.envOr('EFFICIENT_PROP_ETH_NO_ENTRY_BLOCK', uint256(0));
    vm.createSelectFork(rpc, entryBlock);

    assertEq(block.chainid, 1, 'an Ethereum endpoint');
    door = IPropAMMListingDoorTestHooks(d);
    front = door.FRONT();
    listing = door.LISTING();
    token0 = door.TOKEN0();
    token1 = door.TOKEN1();
    IPropAMMFrontTestHooks f = IPropAMMFrontTestHooks(front);
    quoteContract = f.deskCellOf(f.doorView(listing).desk);
    assertGt(quoteContract.code.length, 0, 'the listing is bound to a desk with a quote contract');
    adapter = new EfficientPropAdapter();
  }

  function test_withEntry_token0ForToken1() public {
    _ladder(token0, token1, 0);
  }

  function test_withEntry_token1ForToken0() public {
    _ladder(token1, token0, 0);
  }

  function test_noEntry_token0ForToken1() public {
    _noEntry(token0, token1, 0);
  }

  function test_noEntry_token1ForToken0() public {
    _noEntry(token1, token0, 0);
  }

  function test_front_withEntry_token0ForToken1() public {
    _ladder(token0, token1, 1);
  }

  function test_front_withEntry_token1ForToken0() public {
    _ladder(token1, token0, 1);
  }

  function test_front_noEntry_token0ForToken1() public {
    _noEntry(token0, token1, 1);
  }

  function test_front_noEntry_token1ForToken0() public {
    _noEntry(token1, token0, 1);
  }

  /// @dev Sizes from 10^(decimals - 6) to 5 * 10^(decimals + 6) of the input token, three to each
  ///      power of ten (1, 2 and 5 of it), since a listing's minimum fill and its output bounds can
  ///      leave no power of ten between them. Every size the door quotes is filled from the same
  ///      state in `mode` and must pay the quote.
  function _ladder(address tokenIn, address tokenOut, uint256 mode) internal {
    uint256 dec = IERC20Metadata(tokenIn).decimals();
    uint256 lo = (dec > 6 ? dec - 6 : 0) * 3;
    uint256 filled;
    for (uint256 k = lo; k < (dec + 7) * 3; ++k) {
      uint256 amountIn = _size(k);
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
    if (filled == 0 && IPropAMMFrontTestHooks(front).doorView(listing).creditMode != 0) {
      // a listing with a credit mode may fill no size of a side: a route its pool leaves off
      emit log('a credit listing: no size filled in this direction');
      return;
    }
    assertGt(filled, 0, 'the door filled no size in this direction');
  }

  /// @dev Every size of the ladder the door quotes in the update's block, then the block with no
  ///      update: for each of those sizes the door's quote reverts `NoFill()` and the hop reverts
  ///      whole with `NoWord()`.
  function _noEntry(address tokenIn, address tokenOut, uint256 mode) internal {
    if (noEntryBlock == 0) {
      vm.skip(true, 'set EFFICIENT_PROP_ETH_NO_ENTRY_BLOCK to run in a block without the update');
      return;
    }
    uint256[] memory sizes = _quoted(tokenIn, tokenOut);
    if (sizes.length == 0 && IPropAMMFrontTestHooks(front).doorView(listing).creditMode != 0) {
      emit log('a credit listing: no size quoted in this direction');
      return;
    }
    assertGt(sizes.length, 0, 'the door quoted no size in the update block');

    vm.createSelectFork(rpc, noEntryBlock);
    adapter = new EfficientPropAdapter();
    bytes memory data = abi.encode(address(door), front, uint256(listing), mode);
    for (uint256 i; i < sizes.length; ++i) {
      (bool ok, bytes memory ret) =
        address(door).staticcall(abi.encodeCall(door.quote, (tokenIn, tokenOut, sizes[i])));
      assertFalse(ok, 'the door quotes a size in a block without the update');
      assertEq(ret, abi.encodeWithSelector(NoFill.selector), 'the quote refuses with NoFill');

      deal(tokenIn, address(adapter), sizes[i]);
      vm.expectRevert(NoWord.selector);
      adapter.executeEfficientProp(data, sizes[i], tokenIn, tokenOut, recipient);
    }
  }

  /// @dev The sizes of the ladder the door quotes in the update's block.
  function _quoted(address tokenIn, address tokenOut) internal view returns (uint256[] memory out) {
    uint256 dec = IERC20Metadata(tokenIn).decimals();
    uint256 lo = (dec > 6 ? dec - 6 : 0) * 3;
    uint256[] memory all = new uint256[]((dec + 7) * 3 - lo);
    uint256 n;
    for (uint256 k = lo; k < (dec + 7) * 3; ++k) {
      try door.quote(tokenIn, tokenOut, _size(k)) returns (uint256) {
        all[n++] = _size(k);
      } catch {}
    }
    out = new uint256[](n);
    for (uint256 i; i < n; ++i) {
      out[i] = all[i];
    }
  }

  /// @dev The ladder's k-th size: 1, 2 or 5 times 10^(k / 3).
  function _size(uint256 k) internal pure returns (uint256) {
    uint256 m = k % 3;
    return (m == 0 ? 1 : m == 1 ? 2 : 5) * 10 ** (k / 3);
  }

  /// @dev Fund the adapter, run the hop in `mode`, and check what every fill shares: the
  ///      recipient's balance, which is not zero before the fill, rises by exactly `amountOut`, the
  ///      whole input leaves the adapter, nothing is unused, no approval is left on the door or on
  ///      the front, and exactly one `Swapped` is logged for this fill: by the listing's quote
  ///      contract, with the front's caller as sender (the door in mode 0, the adapter in mode 1),
  ///      and none by the door.
  function _fill(uint256 amountIn, address tokenIn, address tokenOut, uint256 mode)
    internal
    returns (uint256 amountOut)
  {
    deal(tokenIn, address(adapter), amountIn);
    deal(tokenOut, recipient, 7 * 10 ** IERC20Metadata(tokenOut).decimals());
    uint256 recipientBefore = tokenOut.balanceOf(recipient);

    vm.recordLogs();
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
    address sender = mode == 0 ? address(door) : address(adapter);

    Vm.Log[] memory logs = vm.getRecordedLogs();
    uint256 swapped;
    for (uint256 i; i < logs.length; ++i) {
      if (logs[i].topics.length == 0 || logs[i].topics[0] != Swapped.selector) continue;
      assertEq(logs[i].emitter, quoteContract, 'the quote contract logs the fill, not the door');
      assertEq(logs[i].topics[1], bytes32(uint256(uint160(sender))), 'Swapped sender');
      assertEq(logs[i].topics[2], bytes32(uint256(uint160(tokenIn))), 'Swapped tokenIn');
      assertEq(logs[i].topics[3], bytes32(uint256(uint160(tokenOut))), 'Swapped tokenOut');
      assertEq(logs[i].data, abi.encode(amountIn, amountOut, recipient), 'Swapped data');
      ++swapped;
    }
    assertEq(swapped, 1, 'one Swapped for the fill, which the builder matches');
  }
}
