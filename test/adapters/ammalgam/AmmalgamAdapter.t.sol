// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';

import 'src/adapters/ammalgam/AmmalgamAdapter.sol';
import 'src/adapters/ammalgam/IAmmalgamPair.sol';
import 'src/adapters/ammalgam/libraries/DepletedAssetUtils.sol';
import 'src/adapters/ammalgam/libraries/QuadraticSwapFees.sol';

contract AmmalgamAdapterHarness is AmmalgamAdapter {
  function computeExpectedSwapOutAmount(uint256 amountIn, IAmmalgamPair pair, bool xToY)
    external
    view
    returns (uint256 amountOut)
  {
    return _computeExpectedSwapOutAmount(amountIn, pair, xToY);
  }
}

contract AmmalgamTestToken is ERC20 {
  constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

// Self-contained v1.1.1 swap invariant oracle; intentionally independent of adapter math.
contract AmmalgamPairMock is IAmmalgamPair {
  error K();
  error SyncCalled();

  uint256 private constant BORROW_X = 4;
  uint256 private constant BORROW_Y = 5;
  uint256 private constant PAIR_BUFFER = 19;
  uint256 private constant PAIR_BUFFER_NUMERATOR = 20;
  uint256 private constant PAIR_MIN_FEE_Q64 = 0x1999999999999999;
  uint256 private constant PAIR_BIPS_Q64 = 0x27100000000000000000;
  uint256 private constant PAIR_N = 40;
  uint256 private constant PAIR_N_TIMES_BIPS_Q64_PER_PERCENT = 0xfa00000000000000000;
  uint256 private constant PAIR_TWO_Q64 = 0x20000000000000000;
  uint256 private constant PAIR_MAX_QUADRATIC_FEE_Q64 = 0x280000000000000000;
  uint32 private constant INTEREST_PERIOD_FOR_SWAP = 1 days - 1;

  address public immutable tokenX;
  address public immutable tokenY;

  uint112 private reserveX;
  uint112 private reserveY;
  uint112 private immutable referenceReserveX;
  uint112 private immutable referenceReserveY;
  uint112[6] private assetsWithInterest;
  uint32 private lastLendingTimestamp;

  uint256 public lastAmountXOut;
  uint256 public lastAmountYOut;
  address public lastRecipient;

  constructor(address tokenX_, address tokenY_) {
    tokenX = tokenX_;
    tokenY = tokenY_;
    reserveX = 100e18;
    reserveY = 200e18;
    referenceReserveX = 100e18;
    referenceReserveY = 200e18;
    assetsWithInterest[BORROW_X] = 96e18;
    assetsWithInterest[BORROW_Y] = 191e18;
  }

  function setLastLendingTimestamp(uint32 timestamp) external {
    lastLendingTimestamp = timestamp;
  }

  function getReserves()
    external
    view
    override
    returns (uint112 reserveXAssets, uint112 reserveYAssets, uint32 timestamp)
  {
    return (reserveX, reserveY, lastLendingTimestamp);
  }

  function referenceReserves()
    external
    view
    override
    returns (uint112 referenceX, uint112 referenceY)
  {
    return (referenceReserveX, referenceReserveY);
  }

  function totalAssetsAndShares(bool withInterest)
    external
    view
    override
    returns (uint112[6] memory allAssets, uint112[6] memory allShares)
  {
    if (withInterest) allAssets = assetsWithInterest;
    return (allAssets, allShares);
  }

  function sync() external pure {
    revert SyncCalled();
  }

  function swap(uint256 amountXOut, uint256 amountYOut, address to, bytes calldata)
    external
    override
  {
    (uint256 missingX, uint256 missingY) = _missingAssetsForSwap();
    if (amountXOut >= reserveX - missingX || amountYOut >= reserveY - missingY) revert K();

    if (amountXOut > 0) IERC20(tokenX).transfer(to, amountXOut);
    if (amountYOut > 0) IERC20(tokenY).transfer(to, amountYOut);

    uint256 balanceX = IERC20(tokenX).balanceOf(address(this));
    uint256 balanceY = IERC20(tokenY).balanceOf(address(this));
    uint256 amountXIn = _amountIn(amountXOut, balanceX, reserveX);
    uint256 amountYIn = _amountIn(amountYOut, balanceY, reserveY);

    uint256 adjustedBalanceX =
      _balanceAfterFees(amountXIn, balanceX, reserveX, referenceReserveX, missingX);
    uint256 adjustedBalanceY =
      _balanceAfterFees(amountYIn, balanceY, reserveY, referenceReserveY, missingY);
    if (
      adjustedBalanceX * adjustedBalanceY
        < _adjustedReserve(reserveX, missingX) * _adjustedReserve(reserveY, missingY)
    ) revert K();

    reserveX = uint112(uint256(reserveX) + amountXIn - amountXOut);
    reserveY = uint112(uint256(reserveY) + amountYIn - amountYOut);
    lastAmountXOut = amountXOut;
    lastAmountYOut = amountYOut;
    lastRecipient = to;
  }

  function _missingAssetsForSwap() private view returns (uint256 missingX, uint256 missingY) {
    uint32 elapsed;
    unchecked {
      elapsed = uint32(block.timestamp) - lastLendingTimestamp;
    }
    if (elapsed >= INTEREST_PERIOD_FOR_SWAP) {
      missingX = assetsWithInterest[BORROW_X];
      missingY = assetsWithInterest[BORROW_Y];
    }
  }

  function _amountIn(uint256 amountOut, uint256 balance, uint256 reserve)
    private
    pure
    returns (uint256)
  {
    uint256 reserveAfterSwap = reserve - amountOut;
    return balance > reserveAfterSwap ? balance - reserveAfterSwap : 0;
  }

  function _balanceAfterFees(
    uint256 amountIn,
    uint256 balance,
    uint256 reserve,
    uint256 referenceReserve,
    uint256 missing
  ) private pure returns (uint256) {
    uint256 fee = _swapFeeBipsQ64(amountIn, reserve, referenceReserve);
    uint256 feeAdjustedBalance = balance - _ceilDiv(amountIn * fee, PAIR_BIPS_Q64);
    return feeAdjustedBalance * PAIR_BUFFER < missing * PAIR_BUFFER_NUMERATOR
      ? (feeAdjustedBalance - missing) * PAIR_BUFFER_NUMERATOR
      : feeAdjustedBalance;
  }

  function _swapFeeBipsQ64(uint256 input, uint256 currentReserve, uint256 referenceReserve)
    private
    pure
    returns (uint256 fee)
  {
    if (input == 0) return 0;

    unchecked {
      uint256 currentReserveAfterSwap = input + currentReserve;
      if (currentReserve >= referenceReserve) {
        fee = currentReserveAfterSwap + currentReserve > referenceReserve * 3
          ? _linearFeeBipsQ64(input, currentReserve, referenceReserve)
          : _quadraticFeeBipsQ64(input, currentReserve, referenceReserve);
      } else if (currentReserveAfterSwap > referenceReserve) {
        uint256 pastBy = currentReserveAfterSwap - referenceReserve;
        fee = pastBy > referenceReserve
          ? _linearFeeBipsQ64(pastBy, referenceReserve, referenceReserve)
          : _quadraticFeeBipsQ64(pastBy, referenceReserve, referenceReserve);
        fee = fee * pastBy / input;
      }
    }

    return fee > PAIR_MIN_FEE_Q64 ? fee : PAIR_MIN_FEE_Q64;
  }

  function _quadraticFeeBipsQ64(uint256 input, uint256 currentReserve, uint256 referenceReserve)
    private
    pure
    returns (uint256)
  {
    return PAIR_N_TIMES_BIPS_Q64_PER_PERCENT * (input + 2 * (currentReserve - referenceReserve))
      / referenceReserve;
  }

  function _linearFeeBipsQ64(uint256 input, uint256 currentReserve, uint256 referenceReserve)
    private
    pure
    returns (uint256)
  {
    return 4000
      * (PAIR_TWO_Q64
        - referenceReserve
        * PAIR_MAX_QUADRATIC_FEE_Q64
        / (PAIR_N * (input + 2 * (currentReserve - referenceReserve))));
  }

  function _ceilDiv(uint256 numerator, uint256 denominator) private pure returns (uint256) {
    return numerator == 0 ? 0 : (numerator - 1) / denominator + 1;
  }

  function _adjustedReserve(uint256 reserve, uint256 missing) private pure returns (uint256) {
    return reserve * PAIR_BUFFER < missing * PAIR_BUFFER_NUMERATOR
      ? (reserve - missing) * PAIR_BUFFER_NUMERATOR
      : reserve;
  }
}

contract AmmalgamAdapterTest is Test {
  uint256 private constant AMOUNT_IN = 1e18;
  uint256 private constant INTEREST_PERIOD_FOR_SWAP = 86_399;

  AmmalgamAdapterHarness private adapter;
  AmmalgamPairMock private pair;
  AmmalgamTestToken private tokenX;
  AmmalgamTestToken private tokenY;
  address private recipient = makeAddr('recipient');

  function setUp() public {
    adapter = new AmmalgamAdapterHarness();

    AmmalgamTestToken tokenA = new AmmalgamTestToken('A', 'A');
    AmmalgamTestToken tokenB = new AmmalgamTestToken('B', 'B');
    (tokenX, tokenY) = address(tokenA) < address(tokenB) ? (tokenA, tokenB) : (tokenB, tokenA);

    pair = new AmmalgamPairMock(address(tokenX), address(tokenY));
    tokenX.mint(address(pair), 100e18);
    tokenY.mint(address(pair), 200e18);

    vm.warp(1_000_000);
    pair.setLastLendingTimestamp(uint32(block.timestamp));
  }

  function test_computeExpectedSwapOutAmount_usesInterestAt86399Seconds() public {
    uint32 lastLendingTimestamp = 1000;
    pair.setLastLendingTimestamp(lastLendingTimestamp);

    vm.warp(uint256(lastLendingTimestamp) + INTEREST_PERIOD_FOR_SWAP - 1);
    assertEq(adapter.computeExpectedSwapOutAmount(AMOUNT_IN, pair, true), 1_972_355_340_805_576_458);

    vm.warp(uint256(lastLendingTimestamp) + INTEREST_PERIOD_FOR_SWAP);
    assertEq(adapter.computeExpectedSwapOutAmount(AMOUNT_IN, pair, true), 1_794_235_388_310_648_518);
  }

  function test_computeExpectedSwapOutAmount_wrapsUint32ElapsedTime() public {
    pair.setLastLendingTimestamp(type(uint32).max - 100);
    vm.warp(uint256(type(uint32).max) + 1 + 86_298);

    assertEq(adapter.computeExpectedSwapOutAmount(AMOUNT_IN, pair, true), 1_794_235_388_310_648_518);
  }

  function test_executeAmmalgam_xToY_usesPreviewStateWithoutSync() public {
    tokenX.mint(address(adapter), AMOUNT_IN);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeAmmalgam(
      abi.encode(address(pair)), AMOUNT_IN, address(tokenX), address(tokenY), recipient
    );

    assertEq(amountUnused, 0);
    assertEq(amountOut, 1_972_355_340_805_576_458);
    assertEq(tokenY.balanceOf(recipient), amountOut);
    assertEq(pair.lastAmountXOut(), 0);
    assertEq(pair.lastAmountYOut(), amountOut);
    assertEq(pair.lastRecipient(), recipient);
  }

  function test_executeAmmalgam_yToX_usesPreviewStateWithoutSync() public {
    tokenY.mint(address(adapter), AMOUNT_IN);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeAmmalgam(
      abi.encode(address(pair)), AMOUNT_IN, address(tokenY), address(tokenX), recipient
    );

    assertEq(amountUnused, 0);
    assertEq(amountOut, 496_522_353_456_253_296);
    assertEq(tokenX.balanceOf(recipient), amountOut);
    assertEq(pair.lastAmountXOut(), amountOut);
    assertEq(pair.lastAmountYOut(), 0);
    assertEq(pair.lastRecipient(), recipient);
  }

  function test_executeAmmalgam_xToY_isMaximumAcceptedBeforeInterestCheckpoint() public {
    _assertMaximumAccepted(true, INTEREST_PERIOD_FOR_SWAP - 1);
  }

  function test_executeAmmalgam_xToY_isMaximumAcceptedAtInterestCheckpoint() public {
    _assertMaximumAccepted(true, INTEREST_PERIOD_FOR_SWAP);
  }

  function test_executeAmmalgam_yToX_isMaximumAcceptedBeforeInterestCheckpoint() public {
    _assertMaximumAccepted(false, INTEREST_PERIOD_FOR_SWAP - 1);
  }

  function test_executeAmmalgam_yToX_isMaximumAcceptedAtInterestCheckpoint() public {
    _assertMaximumAccepted(false, INTEREST_PERIOD_FOR_SWAP);
  }

  function test_executeAmmalgam_revertsForShortData() public {
    _expectInvalidData(new bytes(31));
  }

  function test_executeAmmalgam_revertsForOverlongData() public {
    _expectInvalidData(abi.encode(address(pair), uint256(0)));
  }

  function test_executeAmmalgam_revertsForLegacyStateData() public {
    _expectInvalidData(abi.encode(address(pair), uint256(0), 0, 0, 0, 0, 0));
  }

  function _expectInvalidData(bytes memory data) private {
    vm.expectRevert(AmmalgamAdapter.InvalidDataLength.selector);
    adapter.executeAmmalgam(data, 0, address(tokenX), address(tokenY), recipient);
  }

  function _assertMaximumAccepted(bool xToY, uint256 elapsed) private {
    uint32 lastLendingTimestamp = 1000;
    pair.setLastLendingTimestamp(lastLendingTimestamp);
    vm.warp(uint256(lastLendingTimestamp) + elapsed);

    address tokenIn = xToY ? address(tokenX) : address(tokenY);
    address tokenOut = xToY ? address(tokenY) : address(tokenX);
    assertEq(tokenX.balanceOf(address(pair)), 100e18);
    assertEq(tokenY.balanceOf(address(pair)), 200e18);

    uint256 amountOut = adapter.computeExpectedSwapOutAmount(AMOUNT_IN, pair, xToY);
    uint256 cleanState = vm.snapshotState();

    AmmalgamTestToken(tokenIn).mint(address(adapter), AMOUNT_IN);
    (, uint256 executedAmountOut) =
      adapter.executeAmmalgam(abi.encode(address(pair)), AMOUNT_IN, tokenIn, tokenOut, recipient);
    assertEq(executedAmountOut, amountOut);
    assertEq(IERC20(tokenOut).balanceOf(recipient), amountOut);

    vm.revertToState(cleanState);
    AmmalgamTestToken(tokenIn).mint(address(pair), AMOUNT_IN);
    vm.expectRevert(AmmalgamPairMock.K.selector);
    if (xToY) {
      pair.swap(0, amountOut + 1, recipient, '');
    } else {
      pair.swap(amountOut + 1, 0, recipient, '');
    }
  }
}

contract AmmalgamMathTest is Test {
  function test_calculateSwapFeeBipsQ64_quadraticToLinearBoundary() public pure {
    uint256 referenceReserve = 100e18;
    uint256 currentReserve = 100e18;

    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(100e18 - 1, currentReserve, referenceReserve),
      73_786_976_294_838_206_463_262
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
      QuadraticSwapFees.calculateSwapFeeBipsQ64(150e18 - 1, currentReserve, referenceReserve),
      49_191_317_529_892_137_642_010
    );
    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(150e18, currentReserve, referenceReserve),
      49_191_317_529_892_137_642_666
    );
    assertEq(
      QuadraticSwapFees.calculateSwapFeeBipsQ64(150e18 + 1, currentReserve, referenceReserve),
      49_191_317_529_892_137_645_497
    );
  }

  function test_computeExpectedSwapOutAmount_usesPostFeeDepletionBoundary() public pure {
    assertEq(_quote(95_946_199_999_999_999_999), 19_723_553_408_055_764_564);
    assertEq(_quote(95_946_200_000_000_000_000), 19_723_553_408_055_764_584);
    assertEq(_quote(95_946_200_000_000_000_001), 19_723_553_408_055_764_588);
  }

  function _quote(uint256 missingIn) private pure returns (uint256 amountOut) {
    return
      DepletedAssetUtils.computeExpectedSwapOutAmount(
        1e18 + 1, 100e18, 100e18, 100e18, missingIn, 0
      );
  }
}
