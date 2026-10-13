// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/algebra-integral/AlgebraIntegralAdapter.sol';
import 'src/adapters/algebra-integral/IAlgebraPool.sol';
import 'src/libraries/TokenHelper.sol';

/// @dev Fork tests against live Morpheus pools on Robinhood Chain.
/// Input tokens sit on the adapter. Algebra callbacks msg.sender, so the adapter must be the
/// direct caller. Kyber CI has no RPC_4663; the fork is skipped unless that variable is set.
contract AlgebraIntegralAdapterTest is Test {
  using TokenHelper for address;

  // Highest-TVL Morpheus pool: WETH / HOOD
  address constant WETH_HOOD = 0xcd9e25506cd72db14286165dd940ccfc032613d3;
  address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
  address constant HOOD = 0xd25a41bb6174e519f9c70e12bf15d6bad5af7377;

  // USDG / AAPL
  address constant USDG_AAPL = 0x0e388514f0fb922bb36bcc4db693e1842f939304;
  address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
  address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

  uint256 constant DUST_IN = 17;
  uint256 constant DUST_OUT = 29;
  uint256 constant DUST_RECIPIENT = 31;

  AlgebraIntegralAdapter adapter;
  address recipient = makeAddr('recipient');

  function setUp() public {
    try vm.createSelectFork('robinhood_mainnet') {
      adapter = new AlgebraIntegralAdapter();
      require(IAlgebraPool(WETH_HOOD).token0() == WETH, 'WETH/HOOD token0');
      require(IAlgebraPool(WETH_HOOD).token1() == HOOD, 'WETH/HOOD token1');
      require(IAlgebraPool(USDG_AAPL).token0() == USDG, 'USDG/AAPL token0');
      require(IAlgebraPool(USDG_AAPL).token1() == AAPL, 'USDG/AAPL token1');
    } catch {
      vm.skip(true, 'set RPC_4663 to fork Robinhood mainnet');
    }
  }

  function test_WethToHood() public {
    _swap(WETH_HOOD, WETH, HOOD, 1e15, recipient, 0);
  }

  function test_HoodToWeth() public {
    _swap(WETH_HOOD, HOOD, WETH, 1e18, recipient, 0);
  }

  function test_UsdgToAapl() public {
    _swap(USDG_AAPL, USDG, AAPL, 1e6, recipient, 0);
  }

  function test_AaplToUsdg() public {
    _swap(USDG_AAPL, AAPL, USDG, 1e15, recipient, 0);
  }

  function test_AdapterRecipientBothDirections() public {
    _swap(WETH_HOOD, WETH, HOOD, 1e15, address(adapter), 0);
    _swap(WETH_HOOD, HOOD, WETH, 1e18, address(adapter), 0);
  }

  function test_CustomSqrtPriceLimit() public {
    if (address(adapter) == address(0)) return;
    (uint160 price,,,,,) = IAlgebraPool(WETH_HOOD).globalState();
    // Mild limit below the current price for zeroToOne (WETH -> HOOD).
    uint160 limit = uint160((uint256(price) * 99) / 100);
    if (limit <= 4_295_128_739) limit = 4_295_128_740;
    _swap(WETH_HOOD, WETH, HOOD, 1e15, recipient, limit);
  }

  function testFuzz_ExactInputWithDust(uint256 amountIn, bool reverse, bool receiveInAdapter)
    public
  {
    address tokenIn = reverse ? HOOD : WETH;
    address tokenOut = reverse ? WETH : HOOD;
    amountIn = reverse ? bound(amountIn, 1e16, 50e18) : bound(amountIn, 1e14, 5e16);
    _swap(
      WETH_HOOD, tokenIn, tokenOut, amountIn, receiveInAdapter ? address(adapter) : recipient, 0
    );
  }

  function _swap(
    address pool,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    address to,
    uint160 limitSqrtPrice
  ) internal {
    if (address(adapter) == address(0)) return;

    uint256 inputBefore = amountIn + DUST_IN;
    deal(tokenIn, address(adapter), inputBefore);

    uint256 adapterOutBefore = DUST_OUT;
    uint256 recipientBefore;
    if (to == address(adapter)) {
      if (tokenOut != tokenIn) deal(tokenOut, address(adapter), adapterOutBefore);
      else adapterOutBefore = inputBefore;
      recipientBefore = adapterOutBefore;
    } else {
      deal(tokenOut, address(adapter), adapterOutBefore);
      deal(tokenOut, to, DUST_RECIPIENT);
      recipientBefore = DUST_RECIPIENT;
    }

    (uint256 amountUnused, uint256 amountOut) = adapter.executeAlgebraIntegral(
      abi.encode(pool, uint256(limitSqrtPrice)), amountIn, tokenIn, tokenOut, to
    );

    assertGt(amountOut, 0);
    assertEq(tokenIn.balanceOf(address(adapter)), inputBefore - (amountIn - amountUnused));

    if (to == address(adapter)) {
      uint256 expectedOut = adapterOutBefore + amountOut;
      if (tokenOut == tokenIn) expectedOut -= amountIn - amountUnused;
      assertEq(tokenOut.balanceOf(address(adapter)), expectedOut);
    } else {
      assertEq(tokenOut.balanceOf(address(adapter)), adapterOutBefore);
      assertEq(tokenOut.balanceOf(to), recipientBefore + amountOut);
    }

    if (limitSqrtPrice == 0) assertEq(amountUnused, 0);
  }
}
