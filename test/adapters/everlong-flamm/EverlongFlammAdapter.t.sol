// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import './IFLAMMTestHooks.sol';
import 'src/adapters/everlong-flamm/EverlongFlammAdapter.sol';

/// @notice Fork tests against the live Base FLAMM pool (cbBTC 8d pool asset / USDC 6d loan
/// asset 0): one test per kind, each comparing the adapter's fill against the pool's own
/// preview on the same state it executes against, never against a tolerance.
///
/// The preview is both the oracle and the feasibility filter. The pool refuses sizes for its
/// own reasons — dust, the price band, the notional cap, gate room — and which sizes those are
/// is the pool's business, not the adapter's, so a fuzzed size the preview refuses is skipped
/// rather than asserted on.
contract EverlongFlammAdapterTest is Test {
  using TokenHelper for address;

  address constant POOL = 0xc0fdCB1799cCc2CEBaA1fe247157b0dF33D57572;
  address constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf; // pool asset
  address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // loan asset 0

  uint256 constant KIND_SWAP = 0;
  uint256 constant KIND_LEVER_UP = 1;
  uint256 constant KIND_LEVER_DOWN = 2;

  /// @dev Unpaused, features 63, leverage venue paused with a stale spread post, which is why
  /// the two lever tests arm the venue first.
  uint256 constant PINNED_BLOCK = 51_313_000;

  EverlongFlammAdapter adapter;
  address recipient = makeAddr('recipient');

  /// @dev This suite reads `RPC_8453` itself, with the public endpoint as a default, rather
  /// than `foundry.toml`'s `base_mainnet` alias, which resolves to the same variable but has
  /// no default. An empty value counts as unset: `test.yml` declares `RPC_8453` from a secret
  /// at workflow level, and GitHub renders an unavailable secret as the empty string on a
  /// `pull_request` run raised from a fork, so `envOr`'s default alone is never reached there.
  /// The pinned block is served by the public endpoint; a reviewer holding an archive endpoint
  /// should set `RPC_8453` to it, which is what CI does in the upstream repository.
  function setUp() public {
    string memory rpc = vm.envOr('RPC_8453', string(''));
    if (bytes(rpc).length == 0) rpc = 'https://mainnet.base.org';
    vm.createSelectFork(rpc, PINNED_BLOCK);
    adapter = new EverlongFlammAdapter();
  }

  /// @dev Both directions of the swap venue against `previewSwap`. `poolAssetIn` sells cbBTC
  /// for USDC; the other way buys cbBTC with USDC.
  function test_swap(uint256 amountIn, bool poolAssetIn) public {
    amountIn = bound(amountIn, 1, poolAssetIn ? 1e9 : 1e12);
    (address tokenIn, address tokenOut) = poolAssetIn ? (CBBTC, USDC) : (USDC, CBBTC);

    uint256 expectedUsed;
    uint256 expectedOut;
    try IFLAMMTestHooks(POOL).previewSwap(poolAssetIn, amountIn) returns (
      uint256 used, uint256 out, uint256
    ) {
      (expectedUsed, expectedOut) = (used, out);
    } catch {
      return; // the pool refuses this size; there is no fill for the adapter to reproduce
    }

    (uint256 amountUnused, uint256 amountOut) = _execute(KIND_SWAP, amountIn, tokenIn, tokenOut);
    assertEq(amountOut, expectedOut, 'swap output is the preview');
    assertEq(amountIn - amountUnused, expectedUsed, 'swap consumes what the preview used');
  }

  /// @dev The leverage venue's lever-up leg against `previewLever(true, .)`: pool asset in,
  /// loan asset out.
  function test_leverUp(uint256 amountIn) public {
    _armLeverage();
    amountIn = bound(amountIn, 1, 1e9);

    uint256 expectedUsed;
    uint256 expectedOut;
    try IFLAMMTestHooks(POOL).previewLever(true, amountIn) returns (
      uint256 used, uint256 out, uint256, uint256
    ) {
      (expectedUsed, expectedOut) = (used, out);
    } catch {
      return;
    }

    (uint256 amountUnused, uint256 amountOut) = _execute(KIND_LEVER_UP, amountIn, CBBTC, USDC);
    assertEq(amountOut, expectedOut, 'lever-up output is the preview');
    assertEq(amountIn - amountUnused, expectedUsed, 'lever-up consumes what the preview used');
  }

  /// @dev The lever-down leg against `previewLever(false, .)`: loan asset in, pool asset out.
  /// This is the kind that reports a remainder — the fill is sized on the whole `amountIn` and
  /// only then charged its pay leg, so `amountUnused` is routinely non-zero and is the value
  /// `previewLever`'s `amountInUsed` predicts.
  function test_leverDown(uint256 amountIn) public {
    _armLeverage();
    amountIn = bound(amountIn, 1, 1e12);

    uint256 expectedUsed;
    uint256 expectedOut;
    try IFLAMMTestHooks(POOL).previewLever(false, amountIn) returns (
      uint256 used, uint256 out, uint256, uint256
    ) {
      (expectedUsed, expectedOut) = (used, out);
    } catch {
      return;
    }

    (uint256 amountUnused, uint256 amountOut) = _execute(KIND_LEVER_DOWN, amountIn, USDC, CBBTC);
    assertEq(amountOut, expectedOut, 'lever-down output is the preview');
    assertEq(amountIn - amountUnused, expectedUsed, 'lever-down remainder is the preview');
  }

  /// @dev Fund the adapter, run the hop, and check the three post-conditions every kind shares:
  /// the output lands on the recipient, the unused input stays in this frame for the executor
  /// to sweep, and the pool paid something.
  function _execute(uint256 kind, uint256 amountIn, address tokenIn, address tokenOut)
    internal
    returns (uint256 amountUnused, uint256 amountOut)
  {
    deal(tokenIn, address(adapter), amountIn);
    uint256 recipientBefore = tokenOut.balanceOf(recipient);

    (amountUnused, amountOut) =
      adapter.executeEverlongFlamm(abi.encode(POOL, kind), amountIn, tokenIn, tokenOut, recipient);

    assertGt(amountOut, 0);
    assertEq(tokenIn.balanceOf(address(adapter)), amountUnused, 'unused input stays in adapter');
    assertEq(tokenOut.balanceOf(recipient) - recipientBefore, amountOut, 'paid to recipient');
  }

  /// @dev At the pinned block the leverage venue is paused and the standing spread post has
  /// lapsed, so both lever legs need the curator to unpause and the keeper to re-post the same
  /// spread, which makes it live without changing its value.
  function _armLeverage() internal {
    IEverlongCore core = IEverlongCore(IFLAMMTestHooks(POOL).core());
    vm.prank(core.owner());
    IFLAMMTestHooks(POOL).setLevPaused(false);

    ILeverageSpreadHook hook = ILeverageSpreadHook(IFLAMMTestHooks(POOL).hooks().spreadHook);
    uint24 spread = hook.spread(); // read before the prank, which only covers the next call
    vm.prank(core.keeper());
    hook.setSpread(spread);
  }
}
