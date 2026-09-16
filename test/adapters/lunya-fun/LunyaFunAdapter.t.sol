// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import '../lunya/ArcNativeCoinAuthorityMock.sol';
import 'src/adapters/lunya-fun/LunyaFunAdapter.sol';

interface IERC20Transfer {
  function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Forks the Lunya launchpad on Arc testnet and checks every buy and sell the adapter executes
///      against the launch's own quoteBuy and quoteSell at the same state - the arithmetic the trade
///      itself runs, and the same the kyberswap-dex-lib simulator is held to.
contract LunyaFunAdapterTest is Test {
  using TokenHelper for address;

  LunyaFunAdapter adapter;

  // Arc's USDC is the native coin behind an ERC-20 interface, with no balance slot to deal into,
  // so tests take it from an account that holds some.
  address constant USDC = 0x3600000000000000000000000000000000000000;
  address constant USDC_HOLDER = 0xEc95B9ecb93c9B475a87e1930e04D0114337D987;
  address constant ARC_NATIVE_COIN_AUTHORITY = 0x1800000000000000000000000000000000000000;
  address constant ARC_BLOCKLIST_AUTHORITY = 0x1800000000000000000000000000000000000001;

  // A launch still on its curve, and the token it sells
  address launch = vm.parseAddress('0xef3f2667979ec8ce67c115dd2134eeddbd91f516');
  address launchToken = vm.parseAddress('0x33cfca858036d4ff663c51263c4d6c96f8c54aaf');

  address recipient = makeAddr('recipient');

  string constant RPC_URL = 'https://rpc.testnet.arc.network';

  function setUp() public {
    vm.createSelectFork(RPC_URL, 62_228_901);
    vm.etch(ARC_NATIVE_COIN_AUTHORITY, address(new ArcNativeCoinAuthorityMock()).code);
    vm.allowCheatcodes(ARC_NATIVE_COIN_AUTHORITY);
    // a buy pulls USDC with transferFrom, which consults the blocklist first
    vm.etch(ARC_BLOCKLIST_AUTHORITY, address(new ArcBlocklistAuthorityMock()).code);

    adapter = new LunyaFunAdapter();
  }

  function test_executeLunyaFun_buy(uint256 amountIn) public {
    // from a hundredth of a USDC to five hundred, which is far past what the curve has left
    amountIn = bound(amountIn, 10_000, 500_000_000);
    _fund(USDC, amountIn);

    (uint256 tokensOut,, uint256 refund) = ILunyaLaunch(launch).quoteBuy(amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeLunyaFun(abi.encode(launch), amountIn, USDC, launchToken, recipient);

    assertEq(amountOut, tokensOut);
    assertEq(amountUnused, refund, 'a buy that empties the curve refunds the rest');
    assertEq(amountUnused, USDC.balanceOf(address(adapter)));
    assertEq(amountOut, launchToken.balanceOf(recipient));
  }

  function test_executeLunyaFun_sell(uint256 tokensIn) public {
    tokensIn = bound(tokensIn, 1e18, 1e25);
    _fund(launchToken, tokensIn);

    (uint256 quoteOut,) = ILunyaLaunch(launch).quoteSell(tokensIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeLunyaFun(abi.encode(launch), tokensIn, launchToken, USDC, recipient);

    assertEq(amountOut, quoteOut);
    assertEq(amountUnused, 0);
    assertEq(amountOut, USDC.balanceOf(recipient));
  }

  function _fund(address token, uint256 amount) internal {
    if (token == USDC) {
      vm.prank(USDC_HOLDER);
      IERC20Transfer(USDC).transfer(address(adapter), amount);
    } else {
      deal(token, address(adapter), amount);
    }
  }
}
