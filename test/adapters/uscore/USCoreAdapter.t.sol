// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'src/adapters/uscore/USCoreAdapter.sol';
import 'test/helpers/HyperEVMFork.sol';

interface IUSCoreQuote {
  function quoteExactIn(address tokenIn, uint256 amountIn)
    external
    view
    returns (uint256 amountOut, uint256 fee, uint8 status);
}

contract USCoreAdapterTest is Test {
  using TokenHelper for address;

  struct Balances {
    uint256 input;
    uint256 output;
    uint256 received;
  }

  address constant USDC_POOL = 0xeD2EF1b02f2d82D238d6AF17e6404A4977b0feFA;
  address constant USDT_POOL = 0xB9fA3BdfA88dA2dC78C20ca03472E043992C6671;
  address constant USDC = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
  address constant USDT = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
  address constant WHYPE = 0x5555555555555555555555555555555555555555;

  USCoreAdapter adapter;
  USCoreTestExecutor executor;
  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork('hyperevm_mainnet');
    HyperEVMFork.enableReadPrecompiles();
    adapter = new USCoreAdapter();
    executor = new USCoreTestExecutor();
    (,, uint8 usdcStatus) = IUSCoreQuote(USDC_POOL).quoteExactIn(USDC, 1e6);
    (,, uint8 usdtStatus) = IUSCoreQuote(USDT_POOL).quoteExactIn(USDT, 1e6);
    assertEq(usdcStatus, 0);
    assertEq(usdtStatus, 0);
  }

  function test_USDCToWHYPE() public {
    _fundAndSwap(USDC_POOL, USDC, WHYPE, 1e6, recipient, bytes32(uint256(1)), block.timestamp + 300);
  }

  function test_WHYPEToUSDC() public {
    _fundAndSwap(
      USDC_POOL, WHYPE, USDC, 1e16, recipient, bytes32(uint256(1)), block.timestamp + 300
    );
  }

  function test_USDTToWHYPE() public {
    _fundAndSwap(USDT_POOL, USDT, WHYPE, 1e6, recipient, bytes32(uint256(1)), block.timestamp + 300);
  }

  function test_WHYPEToUSDT() public {
    _fundAndSwap(
      USDT_POOL, WHYPE, USDT, 1e16, recipient, bytes32(uint256(1)), block.timestamp + 300
    );
  }

  function test_ExecutorRecipientBothDirections() public {
    _fundAndSwap(
      USDC_POOL, USDC, WHYPE, 1e6, address(executor), bytes32(uint256(1)), block.timestamp + 300
    );
    _fundAndSwap(
      USDC_POOL, WHYPE, USDC, 1e16, address(executor), bytes32(uint256(1)), block.timestamp + 300
    );
    _fundAndSwap(
      USDT_POOL, USDT, WHYPE, 1e6, address(executor), bytes32(uint256(1)), block.timestamp + 300
    );
    _fundAndSwap(
      USDT_POOL, WHYPE, USDT, 1e16, address(executor), bytes32(uint256(1)), block.timestamp + 300
    );
  }

  function test_ZeroRefCodeAndDeadlineBoundary() public {
    _fundAndSwap(USDC_POOL, USDC, WHYPE, 1e6, recipient, bytes32(0), block.timestamp);
    _fundAndSwap(USDC_POOL, WHYPE, USDC, 1e16, recipient, bytes32(0), block.timestamp);
    _fundAndSwap(USDT_POOL, USDT, WHYPE, 1e6, recipient, bytes32(0), block.timestamp);
    _fundAndSwap(USDT_POOL, WHYPE, USDT, 1e16, recipient, bytes32(0), block.timestamp);
  }

  function testFuzz_ExactInputWithDust(
    uint256 amountIn,
    bool reverse,
    bool useUsdt,
    bool receiveInExecutor,
    bytes32 refCode
  ) public {
    address stable = useUsdt ? USDT : USDC;
    address pool = useUsdt ? USDT_POOL : USDC_POOL;
    address tokenIn = reverse ? WHYPE : stable;
    address tokenOut = reverse ? stable : WHYPE;
    amountIn = reverse ? bound(amountIn, 1e15, 1e17) : bound(amountIn, 1e5, 10e6);
    _fundAndSwap(
      pool,
      tokenIn,
      tokenOut,
      amountIn,
      receiveInExecutor ? address(executor) : recipient,
      refCode,
      block.timestamp + 300
    );
  }

  function test_PreexistingAllowance() public {
    vm.prank(address(executor));
    USDC.forceApprove(USDC_POOL, 3);
    _fundAndSwap(USDC_POOL, USDC, WHYPE, 1e6, recipient, bytes32(0), block.timestamp + 300);
    vm.prank(address(executor));
    USDT.forceApprove(USDT_POOL, 3);
    _fundAndSwap(USDT_POOL, USDT, WHYPE, 1e6, recipient, bytes32(0), block.timestamp + 300);
  }

  function test_ExpiredRollsBackApprovalAndFunds() public {
    _assertExpired(USDC_POOL, USDC, WHYPE, 1e6);
    _assertExpired(USDC_POOL, WHYPE, USDC, 1e16);
    _assertExpired(USDT_POOL, USDT, WHYPE, 1e6);
    _assertExpired(USDT_POOL, WHYPE, USDT, 1e16);
  }

  function test_TwoHopsThroughExecutor() public {
    _fund(USDC, 1e6 + 17);
    _fund(WHYPE, 29);
    _fund(USDT, 31);
    uint256 inputBefore = USDC.balanceOf(address(executor));
    uint256 intermediateBefore = WHYPE.balanceOf(address(executor));
    uint256 outputBefore = USDT.balanceOf(address(executor));
    uint256 receivedBefore = USDT.balanceOf(recipient);
    uint256 deadline = block.timestamp + 300;
    bytes32 refCode = bytes32(uint256(1));

    uint256 intermediate =
      _assertSwap(USDC_POOL, USDC, WHYPE, 1e6, address(executor), refCode, deadline);
    uint256 amountOut =
      _assertSwap(USDT_POOL, WHYPE, USDT, intermediate, recipient, refCode, deadline);

    assertEq(inputBefore - USDC.balanceOf(address(executor)), 1e6);
    assertEq(WHYPE.balanceOf(address(executor)), intermediateBefore);
    assertEq(USDT.balanceOf(address(executor)), outputBefore);
    assertEq(USDT.balanceOf(recipient) - receivedBefore, amountOut);
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
    bytes32 refCode,
    uint256 deadline
  ) internal {
    _fund(tokenIn, amountIn + 17);
    _fund(tokenOut, 29);
    if (to != address(executor)) {
      deal(tokenOut, to, tokenOut.balanceOf(to) + 31);
    }
    _assertSwap(pool, tokenIn, tokenOut, amountIn, to, refCode, deadline);
  }

  function _assertSwap(
    address pool,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    address to,
    bytes32 refCode,
    uint256 deadline
  ) internal returns (uint256 amountOut) {
    (uint256 expected,, uint8 status) = IUSCoreQuote(pool).quoteExactIn(tokenIn, amountIn);
    assertEq(status, 0);
    assertGt(expected, 0);
    Balances memory beforeBalances = Balances(
      tokenIn.balanceOf(address(executor)),
      tokenOut.balanceOf(address(executor)),
      tokenOut.balanceOf(to)
    );
    assertGt(beforeBalances.input, amountIn);
    assertGt(beforeBalances.output, 0);

    vm.expectCall(
      pool,
      abi.encodeCall(IUSCorePool.swapExactIn, (tokenIn, amountIn, 1, to, deadline, refCode)),
      1
    );
    bytes memory result = executor.run(
      address(adapter),
      abi.encodeCall(
        USCoreAdapter.executeUSCore,
        (abi.encode(pool, deadline, refCode), amountIn, tokenIn, tokenOut, to)
      )
    );
    uint256 amountUnused;
    (amountUnused, amountOut) = abi.decode(result, (uint256, uint256));

    assertEq(amountUnused, 0);
    assertEq(amountOut, expected);
    assertEq(beforeBalances.input - tokenIn.balanceOf(address(executor)), amountIn);
    assertEq(tokenOut.balanceOf(to) - beforeBalances.received, amountOut);
    assertEq(
      tokenOut.balanceOf(address(executor)),
      beforeBalances.output + (to == address(executor) ? amountOut : 0)
    );
    assertEq(IERC20(tokenIn).allowance(address(executor), pool), 0);
  }

  function _assertExpired(address pool, address tokenIn, address tokenOut, uint256 amountIn)
    internal
  {
    _fund(tokenIn, amountIn + 17);
    _fund(tokenOut, 29);
    vm.prank(address(executor));
    tokenIn.forceApprove(pool, 3);
    uint256 inputBefore = tokenIn.balanceOf(address(executor));
    uint256 outputBefore = tokenOut.balanceOf(address(executor));
    uint256 receivedBefore = tokenOut.balanceOf(recipient);
    uint256 allowanceBefore = IERC20(tokenIn).allowance(address(executor), pool);

    vm.expectRevert(bytes4(keccak256('Expired()')));
    executor.run(
      address(adapter),
      abi.encodeCall(
        USCoreAdapter.executeUSCore,
        (abi.encode(pool, block.timestamp - 1, bytes32(0)), amountIn, tokenIn, tokenOut, recipient)
      )
    );

    assertEq(tokenIn.balanceOf(address(executor)), inputBefore);
    assertEq(tokenOut.balanceOf(address(executor)), outputBefore);
    assertEq(tokenOut.balanceOf(recipient), receivedBefore);
    assertEq(IERC20(tokenIn).allowance(address(executor), pool), allowanceBefore);
  }
}

contract USCoreTestExecutor {
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
