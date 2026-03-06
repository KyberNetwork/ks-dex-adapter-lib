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
      adapter.executeBaseline(data, amountIn, WETH, TB5, address(this));

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    assertEq(TB5.balanceOf(address(adapter)), amountOut);
  }

  function test_executeSell() public {
    // First buy some TB5
    uint256 buyAmount = 0.01 ether;
    deal(WETH, address(adapter), buyAmount);

    bytes memory buyData = abi.encode(RELAY, TB5, true);
    (, uint256 tb5Amount) =
      adapter.executeBaseline(buyData, buyAmount, WETH, TB5, address(this));

    // Now sell the TB5
    bytes memory sellData = abi.encode(RELAY, TB5, false);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeBaseline(sellData, tb5Amount, TB5, WETH, address(this));

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    assertEq(WETH.balanceOf(address(adapter)), amountOut);
  }
}
