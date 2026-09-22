// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import '../uniswap-v3/TickMath.sol';
import 'src/adapters/unitflow-v3/UnitFlowV3Adapter.sol';

contract MaliciousUnitFlowPool {
  function fee() external pure returns (uint24) {
    return 100;
  }

  function swap(address, bool, int256, uint160, bytes calldata data)
    external
    returns (int256 amount0, int256 amount1)
  {
    IUnitFlowV3SwapCallback(msg.sender).unitFlowV3SwapCallback(1_000_000, 0, data);
    return (1_000_000, -1_000_000);
  }
}

contract UnitFlowV3AdapterTest is Test {
  using TokenHelper for address;

  UnitFlowV3Adapter adapter;

  address constant UNITFLOW_FACTORY = 0x5bfBCeb73d39F722B1cB83fD2F11736b28c1Be6d;
  address constant UNITFLOW_POSITION_MANAGER = 0x300F5f2861eF0d9D3c6B812797C0A4c8b15C86a8;
  address constant UNITFLOW_ROUTER = 0x6fD8351b9596C1F0b2f2479BfA6A171cb3d0f410;
  address constant ARC_USDC_TRANSFER_PRECOMPILE = 0x1800000000000000000000000000000000000000;

  // 0.01% UnitFlow V3 pool used by Arc transaction
  // 0xfe8e5c74dbc89fc3f0a77aec1278880c5ba5b9787124dbd085702447032125a2.
  address constant POOL = 0x99a0505D58cC5d7bf3513Cc75F2A605A23F0F79F;
  uint256 constant PRE_SWAP_BLOCK = 22_084_941;
  uint256 constant TRANSACTION_AMOUNT_IN = 1_000_000;
  uint256 constant TRANSACTION_AMOUNT_OUT = 1_142_166;
  address constant TRANSACTION_SENDER = 0xC380D0eF7d6DD4264B0CB052C7F257d5C701E23d;

  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork('arc_mainnet', PRE_SWAP_BLOCK);
    // Foundry does not emulate Arc's native/6-decimal USDC transfer precompile.
    // Mock only its three-argument transfer entry point; pool math, callback
    // settlement, and the input-token balance check still execute on the fork.
    vm.mockCall(
      ARC_USDC_TRANSFER_PRECOMPILE,
      abi.encodeWithSelector(bytes4(keccak256('transfer(address,address,uint256)'))),
      abi.encode(true)
    );
    adapter = new UnitFlowV3Adapter();
  }

  function test_deploymentsExistOnArcMainnet() public view {
    assertGt(UNITFLOW_FACTORY.code.length, 0);
    assertGt(UNITFLOW_POSITION_MANAGER.code.length, 0);
    assertGt(UNITFLOW_ROUTER.code.length, 0);
    assertGt(POOL.code.length, 0);
  }

  function test_executeUnitFlowV3_matchesRealTransaction() public {
    address tokenIn = IUniswapV3Pool(POOL).token1();
    address tokenOut = IUniswapV3Pool(POOL).token0();
    vm.prank(TRANSACTION_SENDER);
    tokenIn.safeTransfer(address(adapter), TRANSACTION_AMOUNT_IN);

    bytes memory data = abi.encode(POOL, TickMath.MAX_SQRT_RATIO - 1);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeUnitFlowV3(data, TRANSACTION_AMOUNT_IN, tokenIn, tokenOut, recipient);

    assertEq(amountUnused, 0);
    assertEq(amountOut, TRANSACTION_AMOUNT_OUT);
    assertEq(tokenIn.balanceOf(address(adapter)), 0);
  }

  function test_executeUnitFlowV3_returnsUnusedInputAtPriceLimit() public {
    address tokenIn = IUniswapV3Pool(POOL).token1();
    address tokenOut = IUniswapV3Pool(POOL).token0();
    uint256 amountIn = TRANSACTION_AMOUNT_IN;
    vm.prank(TRANSACTION_SENDER);
    tokenIn.safeTransfer(address(adapter), amountIn);

    (, int24 tick,,,,,) = IUniswapV3Pool(POOL).slot0();
    bytes memory data = abi.encode(POOL, TickMath.getSqrtRatioAtTick(tick + 1));
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeUnitFlowV3(data, amountIn, tokenIn, tokenOut, recipient);

    assertGt(amountUnused, 0);
    assertLt(amountUnused, amountIn);
    assertGt(amountOut, 0);
    assertEq(amountUnused, tokenIn.balanceOf(address(adapter)));
  }

  function test_unitFlowV3SwapCallback_revertsForUnauthorizedCaller() public {
    address tokenIn = IUniswapV3Pool(POOL).token1();
    deal(tokenIn, address(adapter), 1_000_000);

    vm.expectRevert(UnitFlowV3Adapter.InvalidCallbackCaller.selector);
    adapter.unitFlowV3SwapCallback(1_000_000, 0, abi.encode(tokenIn));

    assertEq(tokenIn.balanceOf(address(adapter)), 1_000_000);
  }

  function test_executeUnitFlowV3_revertsForUnregisteredPool() public {
    address tokenIn = IUniswapV3Pool(POOL).token1();
    address tokenOut = IUniswapV3Pool(POOL).token0();
    MaliciousUnitFlowPool maliciousPool = new MaliciousUnitFlowPool();
    deal(tokenIn, address(adapter), TRANSACTION_AMOUNT_IN);

    bytes memory data = abi.encode(address(maliciousPool), TickMath.MAX_SQRT_RATIO - 1);
    vm.expectRevert(UnitFlowV3Adapter.InvalidPool.selector);
    adapter.executeUnitFlowV3(data, TRANSACTION_AMOUNT_IN, tokenIn, tokenOut, recipient);

    assertEq(tokenIn.balanceOf(address(adapter)), TRANSACTION_AMOUNT_IN);
  }

  function test_calldataEncoding() public pure {
    bytes memory data = abi.encode(POOL, TickMath.MAX_SQRT_RATIO - 1);
    assertEq(data.length, 64);
  }
}
