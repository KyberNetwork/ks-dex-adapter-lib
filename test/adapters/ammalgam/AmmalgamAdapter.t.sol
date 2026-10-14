// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/ammalgam/AmmalgamAdapter.sol';
import 'src/adapters/ammalgam/IAmmalgamPair.sol';
import 'src/adapters/ammalgam/libraries/DepletedAssetUtils.sol';
import 'src/adapters/ammalgam/libraries/QuadraticSwapFees.sol';

contract AmmalgamAdapterHarness is AmmalgamAdapter {
  function computeExpectedSwapOutAmount(uint256 amountIn, IAmmalgamPair pair, bool xToY)
    external
    returns (uint256 amountOut)
  {
    return _computeExpectedSwapOutAmount(amountIn, pair, xToY);
  }
}

contract AmmalgamAdapterTest is Test {
  using TokenHelper for address;

  AmmalgamAdapterHarness adapter;

  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
  address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
  address constant USDC_WETH = 0x728fD0A966B993fe518B00122D51e494F99aBd6a;
  address constant USDC_USDT = 0xf53D16Bc876212Ae501cCCc1949d73BB55Be4b0E;
  uint256 constant BLOCK_NUMBER = 25_949_710;
  uint256 constant CHECKPOINT_BLOCK_NUMBER = 26_181_593;
  uint256 constant INTEREST_PERIOD_FOR_SWAP = 1 days - 1;
  uint256 constant LAST_LENDING_TIMESTAMP_SLOT = 17;

  address[] pools = [USDC_WETH, USDC_USDT];
  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork('mainnet', BLOCK_NUMBER);
    adapter = new AmmalgamAdapterHarness();
  }

  function testFuzz_computeExpectedSwapOutAmount_matchesMaximumAcceptedByPair(
    uint256 amountIn,
    bool xToY,
    bool checkpointElapsed
  ) public {
    vm.createSelectFork('mainnet', CHECKPOINT_BLOCK_NUMBER);
    adapter = new AmmalgamAdapterHarness();

    IAmmalgamPair pool = IAmmalgamPair(USDC_WETH);
    address tokenIn = xToY ? USDC : WETH;
    address tokenOut = xToY ? WETH : USDC;

    uint32 lastLendingTimestamp = _lastLendingTimestamp(pool);
    // 93,612 seconds reproduces the review's +72,000-second USDC/WETH window.
    uint256 lendingElapsed = checkpointElapsed ? 93_612 : 40_000;
    vm.warp(uint256(lastLendingTimestamp) + lendingElapsed);
    uint32 actualLendingElapsed = uint32(block.timestamp) - lastLendingTimestamp;
    if (checkpointElapsed) {
      assertGe(actualLendingElapsed, INTEREST_PERIOD_FOR_SWAP);
    } else {
      assertLt(actualLendingElapsed, INTEREST_PERIOD_FOR_SWAP);
    }

    (uint112 reserveX, uint112 reserveY,) = pool.getReserves();
    uint256 reserveIn = xToY ? reserveX : reserveY;
    amountIn = bound(amountIn, reserveIn / 10_000, reserveIn / 100);

    uint256 expectedAmountOut = adapter.computeExpectedSwapOutAmount(amountIn, pool, xToY);
    uint256 checkpointedState = vm.snapshotState();

    uint256 balanceOutBefore = tokenOut.balanceOf(recipient);
    _swap(pool, tokenIn, amountIn, xToY, expectedAmountOut);
    assertEq(tokenOut.balanceOf(recipient) - balanceOutBefore, expectedAmountOut);

    vm.revertToState(checkpointedState);
    deal(tokenIn, address(this), amountIn);
    tokenIn.safeTransfer(address(pool), amountIn);
    bytes memory swapCall = xToY
      ? abi.encodeCall(IAmmalgamPair.swap, (0, expectedAmountOut + 1, recipient, bytes('')))
      : abi.encodeCall(IAmmalgamPair.swap, (expectedAmountOut + 1, 0, recipient, bytes('')));
    (bool acceptsTooMuch,) = address(pool).call(swapCall);
    assertFalse(acceptsTooMuch);
  }

  function test_executeAmmalgam_readsCheckpointStateAfterDataWasBuilt() public {
    vm.createSelectFork('mainnet', CHECKPOINT_BLOCK_NUMBER);
    adapter = new AmmalgamAdapterHarness();
    IAmmalgamPair pool = IAmmalgamPair(USDC_WETH);
    bytes memory data = abi.encode(address(pool));

    (, uint112 reserveY, uint32 lastUpdateTimestamp) = pool.getReserves();
    uint32 lastLendingTimestamp = _lastLendingTimestamp(pool);
    uint256 amountIn = reserveY / 1000;
    vm.warp(uint256(lastLendingTimestamp) + INTEREST_PERIOD_FOR_SWAP);
    uint32 currentTimestamp = uint32(block.timestamp);
    assertGe(currentTimestamp - lastLendingTimestamp, INTEREST_PERIOD_FOR_SWAP);
    assertLt(currentTimestamp - lastUpdateTimestamp, INTEREST_PERIOD_FOR_SWAP);

    deal(WETH, address(adapter), amountIn);
    uint256 balanceOutBefore = USDC.balanceOf(recipient);
    (, uint256 amountOut) = adapter.executeAmmalgam(data, amountIn, WETH, USDC, recipient);

    assertEq(USDC.balanceOf(recipient) - balanceOutBefore, amountOut);
  }

  function test_executeAmmalgam_revertsForShortData() public {
    _expectInvalidData(new bytes(31));
  }

  function test_executeAmmalgam_revertsForOverlongData() public {
    _expectInvalidData(abi.encode(USDC_WETH, uint256(0)));
  }

  function test_executeAmmalgam_revertsForLegacyStateData() public {
    _expectInvalidData(abi.encode(USDC_WETH, uint256(0), 0, 0, 0, 0, 0));
  }

  function test_executeAmmalgam_readsStateAfterInterveningSwap() public {
    IAmmalgamPair pool = IAmmalgamPair(USDC_WETH);
    bytes memory data = abi.encode(address(pool));
    (, uint112 reserveY,) = pool.getReserves();
    uint256 firstAmountIn = reserveY / 2000;
    uint256 secondAmountIn = reserveY / 1000;

    uint256 firstAmountOut = adapter.computeExpectedSwapOutAmount(firstAmountIn, pool, false);
    _swap(pool, WETH, firstAmountIn, false, firstAmountOut);

    deal(WETH, address(adapter), secondAmountIn);
    uint256 balanceOutBefore = USDC.balanceOf(recipient);
    (, uint256 amountOut) = adapter.executeAmmalgam(data, secondAmountIn, WETH, USDC, recipient);

    assertEq(USDC.balanceOf(recipient) - balanceOutBefore, amountOut);
  }

  function testFuzz_executeAmmalgam_returnsQuotedAmount(
    uint256 poolIndex,
    uint256 amountIn,
    bool xToY
  ) public {
    poolIndex = bound(poolIndex, 0, pools.length - 1);
    IAmmalgamPair pool = IAmmalgamPair(pools[poolIndex]);
    (address tokenX, address tokenY) = _tokens(poolIndex);
    address tokenIn = xToY ? tokenX : tokenY;
    address tokenOut = xToY ? tokenY : tokenX;
    (uint112 reserveX, uint112 reserveY,) = pool.getReserves();
    uint256 reserveIn = xToY ? reserveX : reserveY;
    amountIn = bound(amountIn, reserveIn / 10_000, reserveIn / 100);

    uint256 expectedAmountOut = adapter.computeExpectedSwapOutAmount(amountIn, pool, xToY);
    deal(tokenIn, address(adapter), amountIn);
    uint256 balanceOutBefore = tokenOut.balanceOf(recipient);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeAmmalgam(abi.encode(address(pool)), amountIn, tokenIn, tokenOut, recipient);

    assertEq(amountUnused, 0);
    assertEq(amountOut, expectedAmountOut);
    assertEq(tokenOut.balanceOf(recipient) - balanceOutBefore, amountOut);
    assertEq(tokenIn.balanceOf(address(adapter)), 0);
  }

  function _lastLendingTimestamp(IAmmalgamPair pool) private view returns (uint32) {
    bytes32 lendingSlot = vm.load(address(pool), bytes32(LAST_LENDING_TIMESTAMP_SLOT));
    return uint32(uint256(lendingSlot) >> 224);
  }

  function _expectInvalidData(bytes memory data) private {
    vm.expectRevert(AmmalgamAdapter.InvalidDataLength.selector);
    adapter.executeAmmalgam(data, 0, WETH, USDC, recipient);
  }

  function _swap(
    IAmmalgamPair pool,
    address tokenIn,
    uint256 amountIn,
    bool xToY,
    uint256 amountOut
  ) private {
    deal(tokenIn, address(this), amountIn);
    tokenIn.safeTransfer(address(pool), amountIn);
    if (xToY) {
      pool.swap(0, amountOut, recipient, '');
    } else {
      pool.swap(amountOut, 0, recipient, '');
    }
  }

  function _tokens(uint256 poolIndex) private pure returns (address tokenX, address tokenY) {
    tokenX = USDC;
    tokenY = poolIndex == 0 ? WETH : USDT;
  }
}

contract AmmalgamMathTest is Test {
  function test_calculateSwapFeeBipsQ64_quadraticToLinearBoundary() public pure {
    uint256 referenceReserve = 100e18;
    uint256 currentReserve = 150e18;

    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(100e18 - 1, currentReserve, referenceReserve),
      73_786_976_294_838_206_463_631
    );
    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(100e18, currentReserve, referenceReserve),
      73_786_976_294_838_206_464_000
    );
    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(100e18 + 1, currentReserve, referenceReserve),
      73_786_976_294_838_206_468_000
    );
  }

  function test_calculateSwapFeeBipsQ64_crossReferenceBoundary() public pure {
    uint256 referenceReserve = 100e18;
    uint256 currentReserve = 50e18;

    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(250e18 - 1, currentReserve, referenceReserve),
      59_029_581_035_870_565_170_845
    );
    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(250e18, currentReserve, referenceReserve),
      59_029_581_035_870_565_171_200
    );
    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(250e18 + 1, currentReserve, referenceReserve),
      59_029_581_035_870_565_174_459
    );
  }

  function test_computeExpectedSwapOutAmount_outputDepletionBoundary() public pure {
    assertEq(_quote(0, 95e18 - 1), 49_406_918_948_890_078);
    assertEq(_quote(0, 95e18), 49_406_918_948_890_077);
    assertEq(_quote(0, 95e18 + 1), 49_406_918_948_890_077);
  }

  function test_computeExpectedSwapOutAmount_inputDepletionBoundary() public pure {
    assertEq(_quote(95.95e18 - 1, 0), 19_800_392_086_972_019_228);
    assertEq(_quote(95.95e18, 0), 19_800_392_086_972_019_247);
    assertEq(_quote(95.95e18 + 1, 0), 19_770_206_022_187_004_758);
  }

  function _quote(uint256 missingIn, uint256 missingOut) private pure returns (uint256 amountOut) {
    return DepletedAssetUtils.computeExpectedSwapOutAmount(
      1e18, 100e18, 100e18, 100e18, missingIn, missingOut
    );
  }
}
