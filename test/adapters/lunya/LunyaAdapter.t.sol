// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import '../uniswap-v3/TickMath.sol';
import './ArcNativeCoinAuthorityMock.sol';
import 'src/adapters/lunya/LunyaAdapter.sol';

interface ILunyaQuoter {
  function quoteExactInputSingle(
    address tokenIn,
    address tokenOut,
    uint8 poolType,
    uint256 amountIn,
    uint160 sqrtPriceLimitX96
  ) external returns (uint256 amountOut);
}

interface IERC20Transfer {
  function transfer(address to, uint256 amount) external returns (bool);
}

/// @dev Forks the Lunya DEX on Arc testnet and checks every swap the adapter executes against
///      LunyaQuoter at the same state, and against what kyberswap-dex-lib's simulator quoted there.
abstract contract LunyaAdapterTestBase is Test {
  using TokenHelper for address;

  LunyaAdapter adapter;

  address constant QUOTER = 0xC602Bc22e2C6bc08eA43b57f45842FF158DDd384;

  // Arc's USDC is the native coin behind an ERC-20 interface, with no balance slot to deal into,
  // so tests take it from an account that holds some.
  address constant USDC = 0x3600000000000000000000000000000000000000;
  address constant USDC_HOLDER = 0xEc95B9ecb93c9B475a87e1930e04D0114337D987;
  address constant ARC_NATIVE_COIN_AUTHORITY = 0x1800000000000000000000000000000000000000;

  uint160 constant MIN_SQRT_RATIO = 4_295_128_739;
  uint160 constant MAX_SQRT_RATIO =
    1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

  string constant RPC_URL = 'https://rpc.testnet.arc.network';

  address recipient = makeAddr('recipient');

  struct SimulatedSwap {
    address pool;
    bool zeroForOne;
    uint256 amountIn;
    uint256 amountOut;
  }

  function _setUpFork(uint256 blockNumber) internal {
    vm.createSelectFork(RPC_URL, blockNumber);
    vm.etch(ARC_NATIVE_COIN_AUTHORITY, address(new ArcNativeCoinAuthorityMock()).code);
    vm.allowCheatcodes(ARC_NATIVE_COIN_AUTHORITY);

    adapter = new LunyaAdapter();
  }

  /// @dev A swap with a price limit up to 50 ticks away, so many of them stop short and leave input unused
  function _checkLimited(
    address pool,
    uint8 poolType,
    uint256 amountIn,
    bool zeroForOne,
    uint256 sqrtPriceLimitX96
  ) internal {
    (address tokenIn, address tokenOut) = _tokens(pool, zeroForOne);

    amountIn = bound(amountIn, tokenIn.balanceOf(pool) / 10_000, tokenIn.balanceOf(pool) / 10);
    _fund(tokenIn, amountIn);

    (, int24 tick,,,) = ILunyaPool(pool).slot0();
    if (zeroForOne) {
      sqrtPriceLimitX96 = bound(
        sqrtPriceLimitX96,
        TickMath.getSqrtRatioAtTick(tick - 50),
        TickMath.getSqrtRatioAtTick(tick - 1)
      );
    } else {
      sqrtPriceLimitX96 = bound(
        sqrtPriceLimitX96,
        TickMath.getSqrtRatioAtTick(tick + 1),
        TickMath.getSqrtRatioAtTick(tick + 50)
      );
    }

    uint256 quoted = _quote(tokenIn, tokenOut, poolType, amountIn, uint160(sqrtPriceLimitX96));
    (uint256 amountUnused, uint256 amountOut) = adapter.executeLunya(
      abi.encode(pool, sqrtPriceLimitX96), amountIn, tokenIn, tokenOut, recipient
    );

    _assertSwap(tokenIn, tokenOut, quoted, amountUnused, amountOut);
  }

  /// @dev A swap with no limit, up to twice the reserve, so some of them run out of liquidity
  function _checkUnlimited(address pool, uint8 poolType, uint256 amountIn, bool zeroForOne)
    internal
  {
    (address tokenIn, address tokenOut) = _tokens(pool, zeroForOne);

    amountIn = bound(amountIn, tokenIn.balanceOf(pool) / 10_000, tokenIn.balanceOf(pool) * 2);
    _fund(tokenIn, amountIn);

    uint160 limit = zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    uint256 quoted = _quote(tokenIn, tokenOut, poolType, amountIn, limit);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeLunya(abi.encode(pool, uint160(0)), amountIn, tokenIn, tokenOut, recipient);

    _assertSwap(tokenIn, tokenOut, quoted, amountUnused, amountOut);
  }

  /// @dev Each swap from the same state, delivering exactly what the simulator quoted
  function _checkSimulated(SimulatedSwap[] memory swaps) internal {
    uint256 snapshot = vm.snapshotState();
    for (uint256 i; i < swaps.length; ++i) {
      SimulatedSwap memory s = swaps[i];
      (address tokenIn, address tokenOut) = _tokens(s.pool, s.zeroForOne);

      _fund(tokenIn, s.amountIn);
      (uint256 amountUnused, uint256 amountOut) = adapter.executeLunya(
        abi.encode(s.pool, uint160(0)), s.amountIn, tokenIn, tokenOut, recipient
      );

      _assertSwap(tokenIn, tokenOut, s.amountOut, amountUnused, amountOut);
      vm.revertToState(snapshot);
    }
  }

  function _assertSwap(
    address tokenIn,
    address tokenOut,
    uint256 expectedOut,
    uint256 amountUnused,
    uint256 amountOut
  ) internal view {
    assertEq(amountOut, expectedOut);
    assertEq(amountUnused, tokenIn.balanceOf(address(adapter)));
    assertEq(amountOut, tokenOut.balanceOf(recipient));
  }

  function _tokens(address pool, bool zeroForOne)
    internal
    view
    returns (address tokenIn, address tokenOut)
  {
    (tokenIn, tokenOut) = zeroForOne
      ? (ILunyaPool(pool).token0(), ILunyaPool(pool).token1())
      : (ILunyaPool(pool).token1(), ILunyaPool(pool).token0());
  }

  /// @dev LunyaQuoter reverts the swap it prices, but balances the native coin mock moved with
  ///      vm.deal survive a revert, so the quote is taken under a snapshot that puts them back
  function _quote(
    address tokenIn,
    address tokenOut,
    uint8 poolType,
    uint256 amountIn,
    uint160 sqrtPriceLimitX96
  ) internal returns (uint256 amountOut) {
    uint256 snapshot = vm.snapshotState();
    amountOut = ILunyaQuoter(QUOTER)
      .quoteExactInputSingle(tokenIn, tokenOut, poolType, amountIn, sqrtPriceLimitX96);
    vm.revertToState(snapshot);
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

/// @dev A CP pool whose fee is charged in token1 (USDC), so selling token0 pays it out of the output, and a
///      CL pool on the default plugin's dynamic fee
contract LunyaAdapterTest is LunyaAdapterTestBase {
  address constant CP_POOL = 0xAe4718880F1fec8617dE099Dfc579fC7B5945B6E;
  address constant CL_POOL = 0x0b74ff3c703804A69A9727041fF54012EB649725;

  address[] pools = [CP_POOL, CL_POOL];
  uint8[] poolTypes = [1, 0];

  function setUp() public {
    _setUpFork(62_219_898);
  }

  function test_executeLunya(
    uint256 poolIndex,
    uint256 amountIn,
    bool zeroForOne,
    uint256 sqrtPriceLimitX96
  ) public {
    poolIndex = bound(poolIndex, 0, 1);
    _checkLimited(pools[poolIndex], poolTypes[poolIndex], amountIn, zeroForOne, sqrtPriceLimitX96);
  }

  function test_executeLunya_noPriceLimit(uint256 poolIndex, uint256 amountIn, bool zeroForOne)
    public
  {
    poolIndex = bound(poolIndex, 0, 1);
    _checkUnlimited(pools[poolIndex], poolTypes[poolIndex], amountIn, zeroForOne);
  }

  function test_executeLunya_matchesSimulator() public {
    SimulatedSwap[] memory swaps = new SimulatedSwap[](8);
    swaps[0] = SimulatedSwap(CP_POOL, true, 20_689_999_999_999_999_962_952, 94_040);
    // fee taken from the USDC output
    swaps[1] = SimulatedSwap(CP_POOL, true, 103_449_999_999_999_999_814_761_041, 313_499_999);
    swaps[2] = SimulatedSwap(CP_POOL, false, 94_999_999, 18_637_943_422_609_919_871_177_557);
    swaps[3] = SimulatedSwap(CP_POOL, false, 474_999_999, 68_505_351_121_359_410_093_470_963);
    swaps[4] = SimulatedSwap(CL_POOL, true, 8_245_757, 6_985_824);
    // runs past the position's lower tick, leaving input unused
    swaps[5] = SimulatedSwap(CL_POOL, true, 247_372_710, 85_181_515);
    swaps[6] = SimulatedSwap(CL_POOL, false, 851_817, 994_514);
    // runs past the position's upper tick
    swaps[7] = SimulatedSwap(CL_POOL, false, 255_545_190, 82_457_068);

    _checkSimulated(swaps);
  }
}

/// @dev A STABLE pool of mUSDB (18 decimals) and mUSDA (6 decimals) on the default plugin's dynamic fee,
///      after two swaps have moved it off balance. Each concrete test forks it at a different fee token.
abstract contract LunyaAdapterStableTestBase is LunyaAdapterTestBase {
  uint8 constant STABLE = 2;

  address stablePool = vm.parseAddress('0xc9ffe87a8f59d4ac9294b4b28df7779637d00bd2');

  function test_executeLunya(uint256 amountIn, bool zeroForOne, uint256 sqrtPriceLimitX96) public {
    _checkLimited(stablePool, STABLE, amountIn, zeroForOne, sqrtPriceLimitX96);
  }

  function test_executeLunya_noPriceLimit(uint256 amountIn, bool zeroForOne) public {
    _checkUnlimited(stablePool, STABLE, amountIn, zeroForOne);
  }
}

/// @dev The fee charged in whichever token is paid in
contract LunyaAdapterStableTest is LunyaAdapterStableTestBase {
  function setUp() public {
    _setUpFork(62_227_122);
  }

  function test_executeLunya_matchesSimulator() public {
    SimulatedSwap[] memory swaps = new SimulatedSwap[](6);
    swaps[0] = SimulatedSwap(stablePool, true, 9_950_027_485_196_216_565, 9_943_184);
    swaps[1] = SimulatedSwap(stablePool, true, 49_750_137_425_981_082_828_647, 49_555_725_280);
    // three times the reserve: deep into the curve's bend
    swaps[2] = SimulatedSwap(stablePool, true, 298_500_824_555_886_496_971_882, 100_436_613_609);
    swaps[3] = SimulatedSwap(stablePool, false, 10_050_048, 10_042_136_469_420_200_958);
    swaps[4] = SimulatedSwap(stablePool, false, 90_450_438_249, 88_502_076_283_956_578_930_562);
    swaps[5] = SimulatedSwap(stablePool, false, 301_501_460_832, 99_438_521_584_145_131_013_937);

    _checkSimulated(swaps);
  }
}

/// @dev The fee charged in token0 (mUSDB) after setFeeToken(Token0), so buying mUSDB pays it out of the output
contract LunyaAdapterStableFeeInToken0Test is LunyaAdapterStableTestBase {
  function setUp() public {
    _setUpFork(62_228_956);
  }

  function test_executeLunya_matchesSimulator() public {
    SimulatedSwap[] memory swaps = new SimulatedSwap[](6);
    // selling mUSDB pays the fee on the input
    swaps[0] = SimulatedSwap(stablePool, true, 9_950_027_485_196_216_565, 9_944_129);
    swaps[1] = SimulatedSwap(stablePool, true, 298_500_824_555_886_496_971_882, 100_436_627_181);
    // buying mUSDB pays it on the output
    swaps[2] = SimulatedSwap(stablePool, false, 10_050_048, 10_043_091_172_302_180_494);
    swaps[3] = SimulatedSwap(stablePool, false, 1_005_004_869, 1_004_259_453_961_169_949_032);
    swaps[4] = SimulatedSwap(stablePool, false, 90_450_438_249, 88_500_654_779_845_028_839_735);
    swaps[5] = SimulatedSwap(stablePool, false, 301_501_460_832, 99_374_783_383_936_180_250_279);

    _checkSimulated(swaps);
  }
}

/// @dev The fee charged in token1 (mUSDA, 6 decimals) after setFeeToken(Token1), so selling mUSDB pays it
///      out of an output brought back from 18 decimals to 6
contract LunyaAdapterStableFeeInToken1Test is LunyaAdapterStableTestBase {
  function setUp() public {
    _setUpFork(62_229_772);
  }

  function test_executeLunya_matchesSimulator() public {
    SimulatedSwap[] memory swaps = new SimulatedSwap[](6);
    // selling mUSDB pays the fee on the output, from a millionth of the reserve up
    swaps[0] = SimulatedSwap(stablePool, true, 99_500_274_851_962_165, 99_455);
    swaps[1] = SimulatedSwap(stablePool, true, 9_950_027_485_196_216_565, 9_945_541);
    swaps[2] = SimulatedSwap(stablePool, true, 49_750_137_425_981_082_828_647, 49_567_287_031);
    swaps[3] = SimulatedSwap(stablePool, true, 298_500_824_555_886_496_971_882, 100_386_500_420);
    // buying mUSDB pays it on the input
    swaps[4] = SimulatedSwap(stablePool, false, 10_050_048, 10_044_518_209_916_644_348);
    swaps[5] = SimulatedSwap(stablePool, false, 301_501_460_832, 99_438_554_218_739_097_886_795);

    _checkSimulated(swaps);
  }
}
