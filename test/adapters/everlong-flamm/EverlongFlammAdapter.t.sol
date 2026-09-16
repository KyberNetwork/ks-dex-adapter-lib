// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import './DelegatecallExecutor.sol';
import './IFLAMMTestHooks.sol';
import 'src/adapters/everlong-flamm/EverlongFlammAdapter.sol';

/// @notice Fork tests against the live Base FLAMM pool (cbBTC 8d pool asset / USDC 6d loan
/// asset 0).
///
/// `test_replaySettledSwap` is the strongest gate: the only swap the pool has settled is
/// re-executed THROUGH THE ADAPTER on a fork of its parent block, and the adapter must
/// reproduce the settled amounts to the wei. Every other fill is checked against the pool's
/// own preview on the same state it executes against — never against a tolerance.
contract EverlongFlammAdapterTest is Test {
  using TokenHelper for address;

  address constant POOL = 0xc0fdCB1799cCc2CEBaA1fe247157b0dF33D57572;
  address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // pool asset
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // loan asset 0
  address constant WETH = 0x4200000000000000000000000000000000000006;

  uint256 constant VENUE_SWAP = 0;
  uint256 constant VENUE_LEVERAGE = 1;

  /// @dev The pool's only settled Swap: sell 15_000 sats -> 11_301_759 USDC, tx
  /// 0x46c3cd72a5860b2fe546e5a2130e066314e3777027151661e1e4f19a935901fa at index 97 of block
  /// 51_302_916. The replay forks the PARENT block, not the tx hash: a tx-hash fork re-executes
  /// the 97 earlier txs, which a cold cache pays against the rate-limited public endpoint. No
  /// earlier tx in that block emits a log from the pool, its hooks, feed, aggregator, routers
  /// or Morpho account; the Morpho loan market's only earlier event is index 37, a lender's
  /// withdrawal, which does not bind this fill. previewSwap(true, 15_000) at the parent block
  /// is (15_000, 11_301_759, 17_499_999_999_999_999), the settled Swap exactly, and the replay
  /// below asserts the settled amounts to the wei, so a divergent parent state fails the test.
  uint256 constant SETTLED_SWAP_PARENT_BLOCK = 51_302_915;
  uint256 constant SETTLED_SELL_IN = 15_000;
  uint256 constant SETTLED_SELL_OUT = 11_301_759;

  /// @dev Unpaused, features 63, leverage venue paused with a stale spread post.
  uint256 constant PINNED_BLOCK = 51_313_000;

  EverlongFlammAdapter adapter;
  address recipient = makeAddr('recipient');

  /// @dev The quotable input bracket per swap direction at PINNED_BLOCK, found on-chain.
  uint256 sellMin;
  uint256 sellMax;
  uint256 buyMin;
  uint256 buyMax;

  function setUp() public {
    vm.createSelectFork('base_mainnet', PINNED_BLOCK);
    adapter = new EverlongFlammAdapter();
    (sellMin, sellMax) = _quotableRange(VENUE_SWAP, true);
    (buyMin, buyMax) = _quotableRange(VENUE_SWAP, false);
  }

  // ------------------------------------------------------------------ swap venue

  function test_replaySettledSwap() public {
    vm.createSelectFork('base_mainnet', SETTLED_SWAP_PARENT_BLOCK);
    EverlongFlammAdapter replay = new EverlongFlammAdapter();
    deal(CBBTC, address(replay), SETTLED_SELL_IN);
    uint256 recipientBefore = USDC.balanceOf(recipient);

    (uint256 amountUnused, uint256 amountOut) = replay.executeEverlongFlamm(
      abi.encode(POOL, VENUE_SWAP), SETTLED_SELL_IN, CBBTC, USDC, recipient
    );

    assertEq(amountOut, SETTLED_SELL_OUT, 'adapter must reproduce the settled amountOut');
    assertEq(amountUnused, 0, 'settled input must be fully consumed');
    assertEq(USDC.balanceOf(recipient) - recipientBefore, SETTLED_SELL_OUT, 'paid to recipient');
    assertEq(CBBTC.balanceOf(address(replay)), 0, 'input fully spent');
    assertEq(IERC20(CBBTC).allowance(address(replay), POOL), 0, 'no standing allowance');
  }

  /// @dev The production shape: the executor DELEGATECALLs the adapter with the route's
  /// `msg.value` still on the frame (an ETH-input route whose FLAMM hop is ERC-20) and passes
  /// itself as recipient. Both directions must settle exactly as previewSwap, with the output,
  /// the unused input and the value all on the executor and no allowance left behind.
  function test_delegatecall_nativeRouteHop() public {
    DelegatecallExecutor executor = new DelegatecallExecutor();
    uint256 routeValue = 0.25 ether;
    vm.deal(address(this), 2 * routeValue);
    bytes memory data = abi.encode(POOL, VENUE_SWAP);

    for (uint256 i; i < 2; i++) {
      bool sell = i == 0;
      (address tokenIn, address tokenOut) = sell ? (CBBTC, USDC) : (USDC, CBBTC);
      uint256 amountIn = sell ? SETTLED_SELL_IN : 10e6;
      (uint256 used, uint256 out,) = IFLAMMTestHooks(POOL).previewSwap(sell, amountIn);
      deal(tokenIn, address(executor), amountIn);
      uint256 outBefore = tokenOut.balanceOf(address(executor));
      uint256 valueBefore = address(executor).balance;

      (uint256 amountUnused, uint256 amountOut) = executor.execute{value: routeValue}(
        address(adapter), data, amountIn, tokenIn, tokenOut, address(executor)
      );

      assertEq(amountIn - amountUnused, used, 'used must match previewSwap');
      assertEq(amountOut, out, 'out must match previewSwap');
      assertGt(amountOut, 0);
      assertEq(tokenIn.balanceOf(address(executor)), amountUnused, 'unused input on the executor');
      assertEq(tokenOut.balanceOf(address(executor)) - outBefore, amountOut, 'paid to executor');
      assertEq(IERC20(tokenIn).allowance(address(executor), POOL), 0, 'no standing allowance');
      assertEq(address(executor).balance - valueBefore, routeValue, 'value untouched');
    }
  }

  /// @dev Canonical adapter test: the fuzzed value picks the direction and, bounded into the
  /// range the pool quotes at the pinned block, is the runtime `amountIn`. The fill must equal
  /// the pool's own preview on the same state. Near both edges the band check sawtooths on the
  /// output grid (1 sat / 1 micro-USDC), so a size inside the range can still be refused; there
  /// the adapter must refuse with the preview's exact revert data.
  function test_executeEverlongFlamm(uint256 amountIn) public {
    bool sell = amountIn % 2 == 0;
    (address tokenIn, address tokenOut) = sell ? (CBBTC, USDC) : (USDC, CBBTC);
    amountIn = sell ? bound(amountIn, sellMin, sellMax) : bound(amountIn, buyMin, buyMax);

    try IFLAMMTestHooks(POOL).previewSwap(sell, amountIn) returns (
      uint256 used, uint256 out, uint256
    ) {
      (uint256 amountUnused, uint256 amountOut) = _execute(VENUE_SWAP, amountIn, tokenIn, tokenOut);
      assertEq(amountIn - amountUnused, used, 'used must match previewSwap');
      assertEq(amountOut, out, 'out must match previewSwap');
    } catch (bytes memory reason) {
      deal(tokenIn, address(adapter), amountIn);
      vm.expectRevert(reason);
      adapter.executeEverlongFlamm(
        abi.encode(POOL, VENUE_SWAP), amountIn, tokenIn, tokenOut, recipient
      );
    }
  }

  /// @dev `_quotableRange` reports the first contiguous bracket, so the fuzz above never
  /// reaches the buys the pool accepts outside it. These four sizes are outside the bracket at
  /// PINNED_BLOCK — two dust buys below `buyMin`, the two ends of the run above `buyMax` — and
  /// the adapter must fill them exactly as previewSwap does. Each runs on the pinned state.
  function test_buy_outsideBracket() public {
    uint256[4] memory sizes = [uint256(790), 1580, 185_399_567, 185_399_768];
    for (uint256 i; i < sizes.length; i++) {
      uint256 snapshot = vm.snapshotState();
      uint256 amountIn = sizes[i];
      assertTrue(amountIn < buyMin || amountIn > buyMax, 'size must be outside the bracket');

      (uint256 used, uint256 out,) = IFLAMMTestHooks(POOL).previewSwap(false, amountIn);
      (uint256 amountUnused, uint256 amountOut) = _execute(VENUE_SWAP, amountIn, USDC, CBBTC);

      assertEq(amountIn - amountUnused, used, 'used must match previewSwap');
      assertEq(amountOut, out, 'out must match previewSwap');
      vm.revertToState(snapshot);
    }
  }

  /// @dev A sell whose output exceeds the loan asset's notional cap is CLIPPED, not refused:
  /// the ceiling bounds the fill and only the consumed part of the input is pulled.
  function test_partialFill_notionalCap() public {
    uint256 amountIn = sellMax;
    (uint256 uncappedUsed, uint256 uncappedOut,) = IFLAMMTestHooks(POOL).previewSwap(true, amountIn);
    assertEq(uncappedUsed, amountIn, 'the uncapped sell fills in full');
    uint256 cap = uncappedOut / 4;
    _setMaxSwapNotional(cap);

    (uint256 used, uint256 out,) = IFLAMMTestHooks(POOL).previewSwap(true, amountIn);
    assertLt(used, amountIn, 'the cap must clip this sell for the test to mean anything');
    (uint256 amountUnused, uint256 amountOut) = _execute(VENUE_SWAP, amountIn, CBBTC, USDC);

    assertGt(amountUnused, 0, 'clipped sell must partially fill');
    assertEq(amountIn - amountUnused, used, 'used must match previewSwap');
    assertEq(amountOut, out, 'out must match previewSwap');
    assertLe(amountOut, cap, 'output bounded by the notional cap');
  }

  /// @dev The buy leg checks the cap on the loan asset it takes in and reverts past it.
  function test_buy_notionalCap_reverts() public {
    uint256 amountIn = buyMax;
    (uint256 uncappedUsed,,) = IFLAMMTestHooks(POOL).previewSwap(false, amountIn);
    assertEq(uncappedUsed, amountIn, 'the uncapped buy fills in full');
    _setMaxSwapNotional(amountIn - 1);
    deal(USDC, address(adapter), amountIn);

    vm.expectRevert(IFLAMMTestHooks.NotionalCap.selector);
    adapter.executeEverlongFlamm(abi.encode(POOL, VENUE_SWAP), amountIn, USDC, CBBTC, recipient);
  }

  function test_sell_priceBand_reverts() public {
    deal(CBBTC, address(adapter), sellMax + 1);
    vm.expectRevert(IFLAMMTestHooks.PriceBand.selector);
    adapter.executeEverlongFlamm(abi.encode(POOL, VENUE_SWAP), sellMax + 1, CBBTC, USDC, recipient);
  }

  function test_buy_priceBand_reverts() public {
    deal(USDC, address(adapter), buyMax + 1);
    vm.expectRevert(IFLAMMTestHooks.PriceBand.selector);
    adapter.executeEverlongFlamm(abi.encode(POOL, VENUE_SWAP), buyMax + 1, USDC, CBBTC, recipient);
  }

  /// @dev The pair is bound to the pool's own getters in both venues: a token the pool does
  /// not trade, or the same token on both legs, is refused by name.
  function test_tokenMismatch() public {
    deal(CBBTC, address(adapter), 1000);
    deal(USDC, address(adapter), 1e6);
    for (uint256 venue; venue <= VENUE_LEVERAGE; venue++) {
      bytes memory data = abi.encode(POOL, venue);
      vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_TokenMismatch.selector);
      adapter.executeEverlongFlamm(data, 1000, CBBTC, WETH, recipient);
      vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_TokenMismatch.selector);
      adapter.executeEverlongFlamm(data, 1e6, WETH, USDC, recipient);
      vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_TokenMismatch.selector);
      adapter.executeEverlongFlamm(data, 1000, CBBTC, CBBTC, recipient);
      vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_TokenMismatch.selector);
      adapter.executeEverlongFlamm(data, 1e6, USDC, USDC, recipient);
    }
  }

  function test_unknownVenue(uint256 venue) public {
    venue = bound(venue, VENUE_LEVERAGE + 1, type(uint256).max);
    deal(CBBTC, address(adapter), 1000);
    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_UnknownVenue.selector);
    adapter.executeEverlongFlamm(abi.encode(POOL, venue), 1000, CBBTC, USDC, recipient);
  }

  // ------------------------------------------------------------------ leverage venue

  function test_lever_paused_reverts() public {
    (,, bool leveragePaused) = IFLAMMTestHooks(POOL).switches();
    assertTrue(leveragePaused, 'the venue is paused at the pinned block');
    deal(CBBTC, address(adapter), 1000);
    deal(USDC, address(adapter), 1e6);

    vm.expectRevert(IFLAMMTestHooks.LevPaused.selector);
    adapter.executeEverlongFlamm(abi.encode(POOL, VENUE_LEVERAGE), 1000, CBBTC, USDC, recipient);
    vm.expectRevert(IFLAMMTestHooks.LevPaused.selector);
    adapter.executeEverlongFlamm(abi.encode(POOL, VENUE_LEVERAGE), 1e6, USDC, CBBTC, recipient);
  }

  /// @dev Unpaused with the keeper's post past `maxSpreadAge`: a lever-up fails closed.
  function test_leverUp_staleSpread_reverts() public {
    _unpauseLeverage();
    ILeverageSpreadHook hook = _spreadHook();
    assertGt(block.timestamp, uint256(hook.lastSetTs()) + hook.maxSpreadAge(), 'post is stale');
    deal(CBBTC, address(adapter), 1000);

    vm.expectRevert(IFLAMMTestHooks.SpreadUnavailable.selector);
    adapter.executeEverlongFlamm(abi.encode(POOL, VENUE_LEVERAGE), 1000, CBBTC, USDC, recipient);
  }

  /// @dev leverUp is all or nothing: the fill equals previewLever and consumes the input.
  function test_leverUp_afterArming() public {
    _armLeverage();
    uint256 amountIn = 10_000;

    (uint256 used, uint256 out,,) = IFLAMMTestHooks(POOL).previewLever(true, amountIn);
    assertEq(used, amountIn);
    (uint256 amountUnused, uint256 amountOut) = _execute(VENUE_LEVERAGE, amountIn, CBBTC, USDC);

    assertEq(amountUnused, 0, 'lever-up consumes the whole input');
    assertEq(amountOut, out, 'out must match previewLever');
  }

  /// @dev leverDown pulls only the net pay leg; the rest of `amountIn` is reported unused and
  /// is still in the adapter when the call returns. That remainder is not spare input:
  /// `FLAMMLeverLib.sol:125-141` sizes the fill on the whole `amountIn` before charging
  /// `payNative`, so the venue re-quoted at `amountIn - amountUnused` fills less, not the same.
  function test_leverDown_reportsPayNative() public {
    _armLeverage();
    uint256 amountIn = 10e6;

    (uint256 payNative, uint256 out,,) = IFLAMMTestHooks(POOL).previewLever(false, amountIn);
    (uint256 amountUnused, uint256 amountOut) = _execute(VENUE_LEVERAGE, amountIn, USDC, CBBTC);

    assertEq(amountIn - amountUnused, payNative, 'used must be previewLever payNative');
    assertGt(amountUnused, 0, 'the virtual leg leaves input unpulled');
    assertEq(amountOut, out, 'out must match previewLever');
  }

  /// @dev Canonical adapter test, leverage venue: armed at the pinned block, the fuzzed value
  /// picks the direction (pool asset in = leverUp) and, bounded into the range previewLever
  /// quotes widened by one unit on each side, is the runtime `amountIn`. Inside the range the
  /// out grid and leverDown's ceilDiv'd pay leg (`payNative = ceilDiv(payL18, scale)`, pulled
  /// instead of `amountIn`) move with size, and the fill must equal previewLever; just outside
  /// it the venue refuses (PriceBand on every edge at the pinned block), and the adapter must
  /// revert with the preview's exact revert data.
  function test_executeEverlongFlamm_leverage(uint256 amountIn) public {
    _armLeverage();
    bool up = amountIn % 2 == 0;
    (address tokenIn, address tokenOut) = up ? (CBBTC, USDC) : (USDC, CBBTC);
    (uint256 lo, uint256 hi) = _quotableRange(VENUE_LEVERAGE, up);
    amountIn = bound(amountIn, lo > 1 ? lo - 1 : lo, hi + 1);

    try IFLAMMTestHooks(POOL).previewLever(up, amountIn) returns (
      uint256 used, uint256 out, uint256, uint256
    ) {
      (uint256 amountUnused, uint256 amountOut) =
        _execute(VENUE_LEVERAGE, amountIn, tokenIn, tokenOut);
      assertEq(amountIn - amountUnused, used, 'used must match previewLever');
      assertEq(amountOut, out, 'out must match previewLever');
    } catch (bytes memory reason) {
      deal(tokenIn, address(adapter), amountIn);
      vm.expectRevert(reason);
      adapter.executeEverlongFlamm(
        abi.encode(POOL, VENUE_LEVERAGE), amountIn, tokenIn, tokenOut, recipient
      );
    }
  }

  /// @dev Unpaused with a stale post: a lever-down degrades to the last live spread, which on
  /// a venue that has never filled is the 100_000 ppm ceiling — outside this pool's 8% band.
  /// Preview and execution refuse identically.
  function test_leverDown_staleSpread_degrades() public {
    _unpauseLeverage();
    uint256 amountIn = 10e6;
    deal(USDC, address(adapter), amountIn);

    try IFLAMMTestHooks(POOL).previewLever(false, amountIn) {
      fail('a degraded lever-down must not quote at the pinned block');
    } catch (bytes memory reason) {
      assertEq(bytes4(reason), IFLAMMTestHooks.PriceBand.selector);
    }
    vm.expectRevert(IFLAMMTestHooks.PriceBand.selector);
    adapter.executeEverlongFlamm(abi.encode(POOL, VENUE_LEVERAGE), amountIn, USDC, CBBTC, recipient);
  }

  // ------------------------------------------------------------------ helpers

  /// @dev Deal `amountIn`, execute, and close the accounting on balances: unused input stays
  /// in the adapter, output lands on the recipient, and no allowance outlives the call.
  function _execute(uint256 venue, uint256 amountIn, address tokenIn, address tokenOut)
    internal
    returns (uint256 amountUnused, uint256 amountOut)
  {
    deal(tokenIn, address(adapter), amountIn);
    uint256 recipientBefore = tokenOut.balanceOf(recipient);

    (amountUnused, amountOut) =
      adapter.executeEverlongFlamm(abi.encode(POOL, venue), amountIn, tokenIn, tokenOut, recipient);

    assertGt(amountOut, 0);
    assertEq(tokenIn.balanceOf(address(adapter)), amountUnused, 'unused input stays in adapter');
    assertEq(tokenOut.balanceOf(recipient) - recipientBefore, amountOut, 'paid to recipient');
    assertEq(IERC20(tokenIn).allowance(address(adapter), POOL), 0, 'no standing allowance');
  }

  /// @dev Whether the venue's own preview quotes `amountIn`; `sell` is pool asset in (for the
  /// leverage venue, leverUp).
  function _quotes(uint256 venue, bool sell, uint256 amountIn) internal view returns (bool) {
    if (venue == VENUE_SWAP) {
      try IFLAMMTestHooks(POOL).previewSwap(sell, amountIn) returns (uint256, uint256, uint256) {
        return true;
      } catch {
        return false;
      }
    }
    try IFLAMMTestHooks(POOL).previewLever(sell, amountIn) returns (
      uint256, uint256, uint256, uint256
    ) {
      return true;
    } catch {
      return false;
    }
  }

  /// @dev The FIRST contiguous bracket of quotable sizes, not the venue's whole accepted set:
  /// doubling from 1 finds a quotable seed, and each edge is then bisected inside
  /// [seed >> 1, seed] and [seed, seed << 1], so accepted sizes further out are never reached.
  /// At PINNED_BLOCK the sell leg brackets [1, 140_550] and nothing above quotes (checked to
  /// +40_000 and over 64 log-spaced probes up to 5x), while the buy leg brackets
  /// [2_297, 185_398_907] and the pool also quotes 286 smaller buys ([766, 860] and
  /// [1_531, 1_721]) and 202 larger ones ([185_399_567, 185_399_768]) — see
  /// test_buy_outsideBracket. Inside the bracket the set is not an interval either: dust and
  /// band-edge sizes alternate between quoting and refusing on the 1 sat / 1 micro-USDC output
  /// grid, which is why every caller checks the preview for the size it is about to run.
  function _quotableRange(uint256 venue, bool sell) internal view returns (uint256 lo, uint256 hi) {
    uint256 seed = 1;
    while (!_quotes(venue, sell, seed)) {
      seed <<= 1;
      require(seed < 1 << 64, 'no quotable size');
    }
    uint256 bad = seed >> 1;
    lo = seed;
    while (lo - bad > 1) {
      uint256 mid = (lo + bad) >> 1;
      if (_quotes(venue, sell, mid)) lo = mid;
      else bad = mid;
    }
    hi = seed;
    bad = seed << 1;
    while (_quotes(venue, sell, bad)) {
      hi = bad;
      bad <<= 1;
      require(bad < 1 << 64, 'unbounded quotable size');
    }
    while (bad - hi > 1) {
      uint256 mid = (hi + bad) >> 1;
      if (_quotes(venue, sell, mid)) hi = mid;
      else bad = mid;
    }
  }

  function _curator() internal view returns (address) {
    return IEverlongCore(IFLAMMTestHooks(POOL).core()).owner();
  }

  function _spreadHook() internal view returns (ILeverageSpreadHook) {
    return ILeverageSpreadHook(IFLAMMTestHooks(POOL).hooks().spreadHook);
  }

  function _setMaxSwapNotional(uint256 cap) internal {
    (,, uint64 band, uint64 feeFloor,, uint256 reserveTarget,) = IFLAMMTestHooks(POOL).loanConfig(0);
    vm.prank(_curator());
    IFLAMMTestHooks(POOL).setLoanConfig(0, band, feeFloor, cap, reserveTarget);
  }

  function _unpauseLeverage() internal {
    vm.prank(_curator());
    IFLAMMTestHooks(POOL).setLevPaused(false);
  }

  /// @dev Unpause and have the keeper re-post the standing spread, which makes it live.
  function _armLeverage() internal {
    _unpauseLeverage();
    ILeverageSpreadHook hook = _spreadHook();
    uint24 spread = hook.spread();
    vm.prank(IEverlongCore(IFLAMMTestHooks(POOL).core()).keeper());
    hook.setSpread(spread);
  }
}
