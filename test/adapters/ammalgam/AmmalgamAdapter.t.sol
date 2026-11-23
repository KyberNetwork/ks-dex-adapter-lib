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

contract AmmalgamPairMock is IAmmalgamPair {
  error SyncCalled();

  uint256 private constant BORROW_X = 4;
  uint256 private constant BORROW_Y = 5;

  address public immutable tokenX;
  address public immutable tokenY;

  uint112 private immutable reserveX;
  uint112 private immutable reserveY;
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
    lastAmountXOut = amountXOut;
    lastAmountYOut = amountYOut;
    lastRecipient = to;

    if (amountXOut > 0) IERC20(tokenX).transfer(to, amountXOut);
    if (amountYOut > 0) IERC20(tokenY).transfer(to, amountYOut);
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
    tokenX.mint(address(pair), 1000e18);
    tokenY.mint(address(pair), 1000e18);

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
