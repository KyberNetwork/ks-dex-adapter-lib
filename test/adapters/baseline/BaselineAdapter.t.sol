// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/baseline/BaselineAdapter.sol';

contract BaselineAdapterTest is Test {
  using TokenHelper for address;

  BaselineAdapter adapter;

  // Base Sepolia testnet addresses
  address constant RELAY = 0xf020C709fe9Ae902e3CDED1E50CA01021ce968E8;
  address constant WETH = 0xB85885897D297000A74eA2e4711C3Ca729461ABC;
  address constant TB5 = 0x39EEaf94bb996C5E19aE51EAe392a11c5e7b6b84;

  address recipient = makeAddr('recipient');

  string RPC_URL = 'https://sepolia.base.org';
  uint256 BLOCK_NUMBER = 38_500_000;

  function setUp() public {
    vm.createSelectFork(RPC_URL, BLOCK_NUMBER);
    adapter = new BaselineAdapter();
  }

  function test_executeBuy() public {
    uint256 amountIn = 0.01 ether;
    deal(WETH, address(adapter), amountIn);

    bytes memory data = abi.encode(RELAY, TB5, true);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeBaseline(data, amountIn, WETH, TB5, recipient);

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    // Output tokens stay in the adapter
    assertEq(TB5.balanceOf(address(adapter)), amountOut);
    // Input fully consumed (BSwap sweeps any dust as fee)
    assertEq(WETH.balanceOf(address(adapter)), 0);
  }

  function test_executeSell() public {
    uint256 buyAmount = 0.01 ether;
    deal(WETH, address(adapter), buyAmount);

    bytes memory buyData = abi.encode(RELAY, TB5, true);
    (, uint256 tb5Amount) = adapter.executeBaseline(buyData, buyAmount, WETH, TB5, recipient);

    bytes memory sellData = abi.encode(RELAY, TB5, false);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeBaseline(sellData, tb5Amount, TB5, WETH, recipient);

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    assertEq(WETH.balanceOf(address(adapter)), amountOut);
    assertEq(TB5.balanceOf(address(adapter)), 0);
  }

  /// @notice Buy then immediately sell — net reserve loss should be bounded by curve + fees
  function test_buyThenSell_roundtrip() public {
    uint256 amountIn = 0.01 ether;
    deal(WETH, address(adapter), amountIn);

    bytes memory buyData = abi.encode(RELAY, TB5, true);
    (, uint256 tb5Received) = adapter.executeBaseline(buyData, amountIn, WETH, TB5, recipient);

    bytes memory sellData = abi.encode(RELAY, TB5, false);
    (, uint256 wethReturned) = adapter.executeBaseline(sellData, tb5Received, TB5, WETH, recipient);

    // Roundtrip should lose some reserve to fees/spread but never gain
    assertLt(wethReturned, amountIn);
    // Sanity: shouldn't lose more than 20% on a small trade
    assertGt(wethReturned, (amountIn * 80) / 100);
    // No leftover balances
    assertEq(TB5.balanceOf(address(adapter)), 0);
  }

  /// @notice Zero-amount buy reverts: quote returns 0, tripping BSwap's SlippageExceeded
  function test_revert_buy_zeroAmountIn() public {
    bytes memory data = abi.encode(RELAY, TB5, true);
    vm.expectRevert();
    adapter.executeBaseline(data, 0, WETH, TB5, recipient);
  }

  /// @notice Zero-amount sell reverts: MakerLib.swapTokens rejects deltaCirc == 0
  function test_revert_sell_zeroAmountIn() public {
    bytes memory data = abi.encode(RELAY, TB5, false);
    vm.expectRevert();
    adapter.executeBaseline(data, 0, TB5, WETH, recipient);
  }

  /// @notice Adapter can't pay relay if it doesn't hold the promised input balance
  function test_revert_buy_insufficientBalance() public {
    uint256 amountIn = 0.01 ether;
    deal(WETH, address(adapter), amountIn / 10);

    bytes memory data = abi.encode(RELAY, TB5, true);
    vm.expectRevert();
    adapter.executeBaseline(data, amountIn, WETH, TB5, recipient);
  }

  /// @notice Random non-bToken address should not be swappable
  function test_revert_invalidBToken() public {
    address fakeToken = makeAddr('fakeBToken');
    uint256 amountIn = 0.01 ether;
    deal(WETH, address(adapter), amountIn);

    bytes memory data = abi.encode(RELAY, fakeToken, true);
    vm.expectRevert();
    adapter.executeBaseline(data, amountIn, WETH, fakeToken, recipient);
  }

  /// @notice Adapter produces consistent output across a range of input sizes
  function test_fuzz_executeBuy(uint256 amountIn) public {
    amountIn = bound(amountIn, 1e13, 1e17);
    deal(WETH, address(adapter), amountIn);

    bytes memory data = abi.encode(RELAY, TB5, true);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeBaseline(data, amountIn, WETH, TB5, recipient);

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    assertEq(TB5.balanceOf(address(adapter)), amountOut);
    assertEq(WETH.balanceOf(address(adapter)), 0);
  }

  /// @notice Back-to-back swaps must not break on leftover allowances (USDT-style reset path)
  function test_forceApprove_consecutiveBuys() public {
    uint256 amountIn = 0.005 ether;

    deal(WETH, address(adapter), amountIn);
    bytes memory data = abi.encode(RELAY, TB5, true);
    adapter.executeBaseline(data, amountIn, WETH, TB5, recipient);

    deal(WETH, address(adapter), amountIn);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeBaseline(data, amountIn, WETH, TB5, recipient);

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
  }
}
