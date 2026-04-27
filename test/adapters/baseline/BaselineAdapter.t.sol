// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/baseline/BaselineAdapter.sol';

contract BaselineAdapterTest is Test {
  using TokenHelper for address;

  BaselineAdapter adapter;

  // Ethereum mainnet addresses
  address constant RELAY = 0xc81Fd894C0acE037d133aF4886550aC8133568E8;
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address constant B = 0x9fDbDE76236998Dc2836FE67A9954eDE456A1D63;

  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork(vm.envString('ETH_RPC_URL'));
    adapter = new BaselineAdapter();
  }

  function test_executeBuy() public {
    uint256 amountIn = 0.01 ether;
    deal(WETH, address(adapter), amountIn);

    (uint256 quotedOut,,) = IBaseline(RELAY).quoteBuyExactIn(B, amountIn);
    bytes memory data = abi.encode(RELAY, B, true, quotedOut);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeBaseline(data, amountIn, WETH, B, recipient);

    assertEq(amountOut, quotedOut);
    assertEq(B.balanceOf(address(adapter)), amountOut);
    assertEq(WETH.balanceOf(address(adapter)), amountUnused);
  }

  function test_executeSell() public {
    uint256 buyAmount = 0.01 ether;
    deal(WETH, address(adapter), buyAmount);

    (uint256 quotedOut,,) = IBaseline(RELAY).quoteBuyExactIn(B, buyAmount);
    bytes memory buyData = abi.encode(RELAY, B, true, quotedOut);
    (uint256 buyDust, uint256 tb5Amount) = adapter.executeBaseline(buyData, buyAmount, WETH, B, recipient);

    bytes memory sellData = abi.encode(RELAY, B, false);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeBaseline(sellData, tb5Amount, B, WETH, recipient);

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    assertEq(WETH.balanceOf(address(adapter)), amountOut + buyDust);
    assertEq(B.balanceOf(address(adapter)), 0);
  }

  /// @notice Buy then immediately sell — net reserve loss should be bounded by curve + fees
  function test_buyThenSell_roundtrip() public {
    uint256 amountIn = 0.01 ether;
    deal(WETH, address(adapter), amountIn);

    (uint256 quotedOut,,) = IBaseline(RELAY).quoteBuyExactIn(B, amountIn);
    bytes memory buyData = abi.encode(RELAY, B, true, quotedOut);
    (uint256 buyDust, uint256 tb5Received) = adapter.executeBaseline(buyData, amountIn, WETH, B, recipient);

    bytes memory sellData = abi.encode(RELAY, B, false);
    (, uint256 wethReturned) = adapter.executeBaseline(sellData, tb5Received, B, WETH, recipient);

    uint256 totalWethRecovered = wethReturned + buyDust;
    // Roundtrip should lose some reserve to fees/spread but never gain
    assertLt(totalWethRecovered, amountIn);
    // Sanity: shouldn't lose more than 20% on a small trade
    assertGt(totalWethRecovered, (amountIn * 80) / 100);
    // No leftover bTokens
    assertEq(B.balanceOf(address(adapter)), 0);
  }

  /// @notice Zero-amount buy reverts
  function test_revert_buy_zeroAmountOut() public {
    bytes memory data = abi.encode(RELAY, B, true, uint256(0));
    vm.expectRevert();
    adapter.executeBaseline(data, 0, WETH, B, recipient);
  }

  /// @notice Zero-amount sell reverts: MakerLib.swapTokens rejects deltaCirc == 0
  function test_revert_sell_zeroAmountIn() public {
    bytes memory data = abi.encode(RELAY, B, false);
    vm.expectRevert();
    adapter.executeBaseline(data, 0, B, WETH, recipient);
  }

  /// @notice Adapter can't pay relay if it doesn't hold the promised input balance
  function test_revert_buy_insufficientBalance() public {
    uint256 amountIn = 0.01 ether;
    deal(WETH, address(adapter), amountIn / 10);

    (uint256 quotedOut,,) = IBaseline(RELAY).quoteBuyExactIn(B, amountIn);
    bytes memory data = abi.encode(RELAY, B, true, quotedOut);
    vm.expectRevert();
    adapter.executeBaseline(data, amountIn, WETH, B, recipient);
  }

  /// @notice Random non-bToken address should not be swappable
  function test_revert_invalidBToken() public {
    address fakeToken = makeAddr('fakeBToken');
    uint256 amountIn = 0.01 ether;
    deal(WETH, address(adapter), amountIn);

    bytes memory data = abi.encode(RELAY, fakeToken, true, uint256(1e18));
    vm.expectRevert();
    adapter.executeBaseline(data, amountIn, WETH, fakeToken, recipient);
  }

  /// @notice Adapter produces consistent output across a range of input sizes
  function test_fuzz_executeBuy(uint256 amountIn) public {
    amountIn = bound(amountIn, 1e13, 1e17);
    deal(WETH, address(adapter), amountIn);

    (uint256 quotedOut,,) = IBaseline(RELAY).quoteBuyExactIn(B, amountIn);
    bytes memory data = abi.encode(RELAY, B, true, quotedOut);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeBaseline(data, amountIn, WETH, B, recipient);

    assertEq(amountOut, quotedOut);
    assertEq(B.balanceOf(address(adapter)), amountOut);
    assertEq(WETH.balanceOf(address(adapter)), amountUnused);
  }

  /// @notice Back-to-back swaps must not break on leftover allowances (USDT-style reset path)
  function test_forceApprove_consecutiveBuys() public {
    uint256 amountIn = 0.005 ether;

    deal(WETH, address(adapter), amountIn);
    (uint256 quotedOut1,,) = IBaseline(RELAY).quoteBuyExactIn(B, amountIn);
    bytes memory data = abi.encode(RELAY, B, true, quotedOut1);
    adapter.executeBaseline(data, amountIn, WETH, B, recipient);

    deal(WETH, address(adapter), amountIn);
    (uint256 quotedOut2,,) = IBaseline(RELAY).quoteBuyExactIn(B, amountIn);
    bytes memory data2 = abi.encode(RELAY, B, true, quotedOut2);
    (, uint256 amountOut) =
      adapter.executeBaseline(data2, amountIn, WETH, B, recipient);

    assertGt(amountOut, 0);
  }
}
