// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/slyng-fun/SlyngFunAdapter.sol';

/// @notice Fork tests against Slyng's live launchpad on Robinhood Chain mainnet. SLYNG, the
///         launchpad's own coin, is priced in ETH and still on its curve; an ERC-20-quoted curve
///         is opened inside the test, which also puts its opening surcharge under test.
contract SlyngFunAdapterTest is Test {
  using TokenHelper for address;

  SlyngFunAdapter adapter;

  address constant LAUNCHPAD = 0xCe0ABC33eC4264377045Ae17F9B887DB33Cc95B4;
  address constant SLYNG = 0x066FFa6AAF8B54C6094d1Ed1bE818AFA5e0f290E;
  address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
  address constant NATIVE = TokenHelper.NATIVE_ADDRESS;

  uint256 constant BPS = 10_000;

  address recipient = makeAddr('recipient');
  address creator = makeAddr('creator');

  function setUp() public {
    vm.createSelectFork(vm.envOr('RPC_4663', string('https://rpc.mainnet.chain.robinhood.com')));
    adapter = new SlyngFunAdapter();
  }

  function _expectedBuy(address token, uint256 amountIn) internal view returns (uint256) {
    ISlyngLaunchpad lp = ISlyngLaunchpad(LAUNCHPAD);
    uint256 fee = amountIn * lp.TRADE_FEE_BPS() / BPS;
    uint256 surcharge = amountIn * lp.snipeSurchargeBps(token) / BPS;
    return lp.quoteToTokens(token, amountIn - fee - surcharge);
  }

  function _expectedSell(address token, uint256 tokensIn) internal view returns (uint256) {
    ISlyngLaunchpad lp = ISlyngLaunchpad(LAUNCHPAD);
    (uint256 quoteReserve,,,,,,,,,) = lp.curves(token);
    uint256 gross = lp.tokensToQuote(token, tokensIn);
    if (gross > quoteReserve) gross = quoteReserve;
    return gross - gross * lp.TRADE_FEE_BPS() / BPS;
  }

  function _buy(address quote, address token, uint256 amountIn)
    internal
    returns (uint256 amountOut, uint256 gasUsed)
  {
    bytes memory data = abi.encode(LAUNCHPAD, token);
    uint256 before = gasleft();
    (uint256 amountUnused, uint256 out) =
      adapter.executeSlyngFun(data, amountIn, quote, token, recipient);
    gasUsed = before - gasleft();
    assertEq(amountUnused, 0, 'a buy spends every wei');
    amountOut = out;
  }

  function _sell(address token, address quote, uint256 tokensIn)
    internal
    returns (uint256 amountOut, uint256 gasUsed)
  {
    bytes memory data = abi.encode(LAUNCHPAD, token);
    uint256 before = gasleft();
    (uint256 amountUnused, uint256 out) =
      adapter.executeSlyngFun(data, tokensIn, token, quote, recipient);
    gasUsed = before - gasleft();
    assertEq(amountUnused, 0);
    amountOut = out;
  }

  /// @notice Buy SLYNG with native ETH: the output matches the launchpad's own quote to the wei.
  function test_buySlyngWithEth() public {
    uint256 amountIn = 0.01 ether;
    vm.deal(address(adapter), amountIn);
    uint256 expected = _expectedBuy(SLYNG, amountIn);

    (uint256 amountOut, uint256 gasUsed) = _buy(NATIVE, SLYNG, amountIn);

    assertEq(amountOut, expected, 'quoteToTokens net of the fee');
    assertEq(SLYNG.balanceOf(address(adapter)), amountOut, 'output held for the router');
    assertEq(address(adapter).balance, 0, 'nothing left over');
    emit log_named_uint('gas: buy SLYNG with ETH', gasUsed);
  }

  /// @notice Sell SLYNG for native ETH: the launchpad pays the adapter in ETH via receive().
  function test_sellSlyngForEth() public {
    vm.deal(address(adapter), 0.02 ether);
    (uint256 bought,) = _buy(NATIVE, SLYNG, 0.02 ether);
    uint256 tokensIn = bought / 2;
    uint256 expected = _expectedSell(SLYNG, tokensIn);

    (uint256 amountOut, uint256 gasUsed) = _sell(SLYNG, NATIVE, tokensIn);

    assertEq(amountOut, expected, 'tokensToQuote net of the fee');
    assertEq(address(adapter).balance, amountOut, 'ETH held for the router');
    assertEq(SLYNG.balanceOf(address(adapter)), bought - tokensIn);
    emit log_named_uint('gas: sell SLYNG for ETH', gasUsed);
  }

  /// @notice The wrapped-native address is what the aggregator lists an ETH curve under, but the
  ///         launchpad only takes native ETH; a route must unwrap first, and the adapter refuses
  ///         to guess.
  function test_revert_wrongPair() public {
    vm.deal(address(adapter), 0.01 ether);
    bytes memory data = abi.encode(LAUNCHPAD, SLYNG);
    vm.expectRevert(
      abi.encodeWithSelector(SlyngFunAdapter.NotThisCurve.selector, USDG, NATIVE, SLYNG)
    );
    adapter.executeSlyngFun(data, 1, USDG, NATIVE, recipient);
  }

  /// @notice An ERC-20-quoted curve, opened here: USDG is pulled with transferFrom, the opening
  ///         surcharge applies inside the first thirty seconds and is gone after.
  function test_erc20QuoteWithOpeningSurcharge() public {
    vm.prank(creator);
    address coin = ISlyngLaunchpad(LAUNCHPAD).createToken('Fork Coin', 'FORK', 0, USDG, 0);

    uint256 amountIn = 25e6; // 25 USDG, 6 decimals
    deal(USDG, address(adapter), amountIn * 2);

    // inside the window: half of the input is withheld as the surcharge
    assertEq(ISlyngLaunchpad(LAUNCHPAD).snipeSurchargeBps(coin), 5000);
    uint256 expectedTaxed = _expectedBuy(coin, amountIn);
    (uint256 taxedOut, uint256 gasTaxed) = _buy(USDG, coin, amountIn);
    assertEq(taxedOut, expectedTaxed, 'surcharged buy matches the launchpad');

    // past the window: the same input buys at the plain 1% fee
    vm.warp(block.timestamp + 31);
    assertEq(ISlyngLaunchpad(LAUNCHPAD).snipeSurchargeBps(coin), 0);
    uint256 expectedPlain = _expectedBuy(coin, amountIn);
    (uint256 plainOut,) = _buy(USDG, coin, amountIn);
    assertEq(plainOut, expectedPlain, 'plain buy matches the launchpad');
    assertGt(plainOut, taxedOut, 'the surcharge cost the early buyer tokens');
    assertEq(USDG.balanceOf(address(adapter)), 0, 'both inputs fully spent');

    // and back out again, paid in USDG
    uint256 tokensIn = coin.balanceOf(address(adapter));
    uint256 expectedSell = _expectedSell(coin, tokensIn);
    (uint256 quoteOut, uint256 gasSell) = _sell(coin, USDG, tokensIn);
    assertEq(quoteOut, expectedSell);
    assertEq(USDG.balanceOf(address(adapter)), quoteOut);
    emit log_named_uint('gas: buy with USDG (surcharged, cold)', gasTaxed);
    emit log_named_uint('gas: sell for USDG', gasSell);
  }

  /// @notice The buy that lifts the reserve to the graduation target graduates the curve in the
  ///         same transaction. The buyer still gets their tokens, and nothing trades on the curve
  ///         after it.
  function test_graduatingBuy() public {
    ISlyngLaunchpad lp = ISlyngLaunchpad(LAUNCHPAD);
    (uint256 quoteReserve,, uint256 graduationTarget,,,,,,, bool graduated) = lp.curves(SLYNG);
    assertFalse(graduated);

    // enough that the net of the fee clears the target
    uint256 amountIn =
      (graduationTarget - quoteReserve) * BPS / (BPS - lp.TRADE_FEE_BPS()) + 1 ether;
    vm.deal(address(adapter), amountIn);
    uint256 expected = _expectedBuy(SLYNG, amountIn);

    (uint256 amountOut, uint256 gasUsed) = _buy(NATIVE, SLYNG, amountIn);

    assertEq(amountOut, expected, 'the graduating buy is priced like any other');
    (,,,,,,,,, graduated) = lp.curves(SLYNG);
    assertTrue(graduated, 'the curve graduated inside the buy');
    emit log_named_uint('gas: buy that graduates the curve', gasUsed);

    vm.deal(address(adapter), 0.01 ether);
    vm.expectRevert();
    adapter.executeSlyngFun(abi.encode(LAUNCHPAD, SLYNG), 0.01 ether, NATIVE, SLYNG, recipient);
  }
}
