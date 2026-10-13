// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/algebra-integral/AlgebraIntegralAdapter.sol';
import 'src/adapters/algebra-integral/IAlgebraPool.sol';
import 'src/libraries/TokenHelper.sol';

import {IERC20} from 'openzeppelin-contracts/contracts/interfaces/IERC20.sol';

/// @dev Fork tests against live Morpheus (Algebra Integral) pools on Robinhood Chain.
contract AlgebraIntegralAdapterTest is Test {
  using TokenHelper for address;

  struct Balances {
    uint256 input;
    uint256 output;
    uint256 received;
  }

  // Highest-TVL Morpheus pool: WETH / HOOD
  address constant WETH_HOOD = 0xcd9e25506cd72db14286165dd940ccfc032613d3;
  address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
  address constant HOOD = 0xd25a41bb6174e519f9c70e12bf15d6bad5af7377;

  // USDG / AAPL
  address constant USDG_AAPL = 0x0e388514f0fb922bb36bcc4db693e1842f939304;
  address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
  address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;

  AlgebraIntegralAdapter adapter;
  AlgebraIntegralTestExecutor executor;
  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork('robinhood_mainnet');
    adapter = new AlgebraIntegralAdapter();
    executor = new AlgebraIntegralTestExecutor();

    require(IAlgebraPool(WETH_HOOD).token0() == WETH, 'WETH/HOOD token0');
    require(IAlgebraPool(WETH_HOOD).token1() == HOOD, 'WETH/HOOD token1');
    require(IAlgebraPool(USDG_AAPL).token0() == USDG, 'USDG/AAPL token0');
    require(IAlgebraPool(USDG_AAPL).token1() == AAPL, 'USDG/AAPL token1');
  }

  function test_WethToHood() public {
    _fundAndSwap(WETH_HOOD, WETH, HOOD, 1e15, recipient, 0);
  }

  function test_HoodToWeth() public {
    _fundAndSwap(WETH_HOOD, HOOD, WETH, 1e18, recipient, 0);
  }

  function test_UsdgToAapl() public {
    _fundAndSwap(USDG_AAPL, USDG, AAPL, 1e6, recipient, 0);
  }

  function test_AaplToUsdg() public {
    _fundAndSwap(USDG_AAPL, AAPL, USDG, 1e15, recipient, 0);
  }

  function test_ExecutorRecipientBothDirections() public {
    _fundAndSwap(WETH_HOOD, WETH, HOOD, 1e15, address(executor), 0);
    _fundAndSwap(WETH_HOOD, HOOD, WETH, 1e18, address(executor), 0);
  }

  function test_CustomSqrtPriceLimit() public {
    (uint160 price,,,,,) = IAlgebraPool(WETH_HOOD).globalState();
    // Mild limit below current price for zeroToOne (WETH -> HOOD)
    uint160 limit = uint160(uint256(price) * 99 / 100);
    if (limit <= 4_295_128_739) limit = 4_295_128_740;
    _fundAndSwap(WETH_HOOD, WETH, HOOD, 1e15, recipient, limit);
  }

  function testFuzz_ExactInputWithDust(uint256 amountIn, bool reverse, bool receiveInExecutor)
    public
  {
    address tokenIn = reverse ? HOOD : WETH;
    address tokenOut = reverse ? WETH : HOOD;
    amountIn = reverse ? bound(amountIn, 1e16, 50e18) : bound(amountIn, 1e14, 5e16);
    _fundAndSwap(
      WETH_HOOD,
      tokenIn,
      tokenOut,
      amountIn,
      receiveInExecutor ? address(executor) : recipient,
      0
    );
  }

  function _fund(address token, uint256 amount) internal {
    deal(token, address(executor), token.balanceOf(address(executor)) + amount);
  }

  function _fundAndSwap(
    address pool,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    address to,
    uint160 limitSqrtPrice
  ) internal {
    _fund(tokenIn, amountIn + 17);
    _fund(tokenOut, 29);
    if (to != address(executor)) {
      deal(tokenOut, to, tokenOut.balanceOf(to) + 31);
    }
    _assertSwap(pool, tokenIn, tokenOut, amountIn, to, limitSqrtPrice);
  }

  function _assertSwap(
    address pool,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    address to,
    uint160 limitSqrtPrice
  ) internal returns (uint256 amountOut) {
    Balances memory beforeBalances = Balances(
      tokenIn.balanceOf(address(executor)),
      tokenOut.balanceOf(address(executor)),
      tokenOut.balanceOf(to)
    );
    assertGt(beforeBalances.input, amountIn);
    assertGt(beforeBalances.output, 0);

    bytes memory result = executor.run(
      address(adapter),
      abi.encodeCall(
        AlgebraIntegralAdapter.executeAlgebraIntegral,
        (abi.encode(pool, uint256(limitSqrtPrice)), amountIn, tokenIn, tokenOut, to)
      )
    );
    uint256 amountUnused;
    (amountUnused, amountOut) = abi.decode(result, (uint256, uint256));

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    assertEq(beforeBalances.input - tokenIn.balanceOf(address(executor)), amountIn);
    assertEq(tokenOut.balanceOf(to) - beforeBalances.received, amountOut);
    assertEq(
      tokenOut.balanceOf(address(executor)),
      beforeBalances.output + (to == address(executor) ? amountOut : 0)
    );
  }
}

contract AlgebraIntegralTestExecutor {
  function run(address adapter, bytes calldata data) external returns (bytes memory) {
    (bool ok, bytes memory result) = adapter.delegatecall(data);
    if (!ok) {
      assembly ('memory-safe') {
        revert(add(result, 32), mload(result))
      }
    }
    return result;
  }
}
