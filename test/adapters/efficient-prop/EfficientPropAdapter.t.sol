// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import {VmSafe} from 'forge-std/Vm.sol';
import 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';

import 'src/adapters/efficient-prop/EfficientPropAdapter.sol';
import 'src/adapters/efficient-prop/IPropAMMFront.sol';

contract EfficientPropTestToken is ERC20 {
  constructor() ERC20('T', 'T') {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @dev The listing's pool: holds the output and pays it out on the venue's word.
contract EfficientPropMockPool {
  function pay(address token, address to, uint256 amount) external {
    IERC20(token).transfer(to, amount);
  }
}

/// @dev A look-alike of a listing door and of a front, over one listing and its pool. The door's
///      pull entry and the front's named entry pull the input straight to the pool; every entry
///      proves the input by the pool's balance, at least its custody plus `amountIn`, as the real
///      pool does. `payPoolOf` answers the pool, or zero once the listing has a credit mode. A fill
///      pays the recipient at a fixed rate. `setRefuse` makes every fill revert after its input
///      landed, with the pool's balance in the error. Records the last fill's entry and terms.
contract EfficientPropMockVenue is IPropAMMListingDoor, IPropAMMFront {
  error NotLive();
  error CustodyMismatch();
  error Refused(uint256 poolBalance, address recipient);

  address public immutable TOKEN0;
  address public immutable TOKEN1;
  address public immutable POOL;
  uint256 public immutable RATE; // token1 per token0, 1e18-scaled
  uint24 public immutable LISTING;

  bool public credit;
  bool public refuse;
  mapping(address => uint256) public custody;
  bytes32 public lastEntry;
  bytes public lastTerms;

  constructor(address token0_, address token1_, address pool_, uint256 rate_, uint24 listing_) {
    (TOKEN0, TOKEN1, POOL, RATE, LISTING) = (token0_, token1_, pool_, rate_, listing_);
    custody[token0_] = IERC20(token0_).balanceOf(pool_);
    custody[token1_] = IERC20(token1_).balanceOf(pool_);
  }

  function setCredit(bool on) external {
    credit = on;
  }

  function setRefuse(bool on) external {
    refuse = on;
  }

  function payPoolOf(uint24 listing) external view returns (address) {
    return listing == LISTING && !credit ? POOL : address(0);
  }

  function quote(address tokenIn, uint256 amountIn) public view returns (uint256) {
    return tokenIn == TOKEN0 ? (amountIn * RATE) / 1e18 : (amountIn * 1e18) / RATE;
  }

  function swapFrom(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline
  ) external returns (uint256) {
    IERC20(tokenIn).transferFrom(msg.sender, POOL, amountIn);
    return _fill('door', tokenIn, tokenOut, amountIn, minAmountOut, recipient, deadline, LISTING);
  }

  function swapSender(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline,
    uint24 listing
  ) external returns (uint256) {
    IERC20(tokenIn).transferFrom(msg.sender, POOL, amountIn);
    return _fill('named', tokenIn, tokenOut, amountIn, minAmountOut, recipient, deadline, listing);
  }

  function swapExactInPaid(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline,
    uint24 listing
  ) external returns (uint256) {
    if (credit) revert NotLive();
    return _fill('paid', tokenIn, tokenOut, amountIn, minAmountOut, recipient, deadline, listing);
  }

  function _fill(
    bytes32 entry,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline,
    uint24 listing
  ) internal returns (uint256 amountOut) {
    if (listing != LISTING) revert NotLive();
    uint256 held = IERC20(tokenIn).balanceOf(POOL);
    if (held < custody[tokenIn] + amountIn) revert CustodyMismatch();
    if (refuse) revert Refused(held, recipient);
    amountOut = quote(tokenIn, amountIn);
    custody[tokenIn] += amountIn;
    custody[tokenOut] -= amountOut;
    (lastEntry, lastTerms) = (entry, abi.encode(minAmountOut, deadline, recipient));
    EfficientPropMockPool(POOL).pay(tokenOut, recipient, amountOut);
  }
}

/// @notice Unit tests for EfficientPropAdapter against a mock door and a mock front: both
/// directions through each fill mode, and one test for each safety rule:
/// - the paid route's payment and paid call in one frame, with no call between
///   (`test_frontPaid_oneFrame`);
/// - a venue's revert never caught, so a refusal after the payment undoes it
///   (`test_refusalUndoesPayment`);
/// - no approval left on the door or the front, and no input spent past `amountIn` (`_checkFill`,
///   in both fill tests);
/// - a fill mode other than 0, 1 or 2 reverts (`test_unknownModeReverts`; mode 2, a block door,
///   has its own tests in EfficientPropAdapterBlockDoor.t.sol);
/// - the listing id passed whole: the listing is past 16 bits and the front refuses any other id
///   (`test_front_bothDirections`).
/// The fork test checks fills against a real door's quote.
contract EfficientPropAdapterTest is Test {
  EfficientPropAdapter adapter;
  EfficientPropTestToken token0;
  EfficientPropTestToken token1;
  EfficientPropMockPool pool;
  EfficientPropMockVenue door;
  EfficientPropMockVenue front;

  address recipient = makeAddr('recipient');

  uint256 constant RATE = 3000e18; // 1 token0 = 3000 token1
  uint24 constant LISTING = 0x9A1B2C; // past 16 bits
  uint256 constant HELD = 5; // input the adapter holds beside `amountIn`, which a fill leaves

  function setUp() public {
    adapter = new EfficientPropAdapter();
    EfficientPropTestToken a = new EfficientPropTestToken();
    EfficientPropTestToken b = new EfficientPropTestToken();
    (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
    pool = new EfficientPropMockPool();
    token0.mint(address(pool), 1e12 ether);
    token1.mint(address(pool), 1e15 ether);
    door =
      new EfficientPropMockVenue(address(token0), address(token1), address(pool), RATE, LISTING);
    front =
      new EfficientPropMockVenue(address(token0), address(token1), address(pool), RATE, LISTING);
    token0.mint(recipient, 7 ether); // the recipient's balance is never the fill
    token1.mint(recipient, 11 ether);
  }

  function test_door_bothDirections(uint256 amountIn, bool zeroForOne) public {
    _checkFill(door, 0, 'door', amountIn, zeroForOne);
  }

  /// @dev Mode 1: the paid entry where the front names a pool to pay, the named entry where the
  ///      listing has a credit mode.
  function test_front_bothDirections(uint256 amountIn, bool zeroForOne, bool named) public {
    front.setCredit(named);
    _checkFill(front, 1, named ? bytes32('named') : bytes32('paid'), amountIn, zeroForOne);
  }

  /// @dev The adapter's calls on the paid route are exactly the read of the pool to pay, the
  ///      token's `transfer` of the whole input to that pool, then the paid entry.
  function test_frontPaid_oneFrame(bool zeroForOne) public {
    (EfficientPropTestToken tIn, EfficientPropTestToken tOut) = _side(zeroForOne);
    uint256 amountIn = zeroForOne ? 3 ether : 9000 ether;
    tIn.mint(address(adapter), amountIn);

    vm.startStateDiffRecording();
    adapter.executeEfficientProp(_data(1), amountIn, address(tIn), address(tOut), recipient);
    Vm.AccountAccess[] memory a = vm.stopAndReturnStateDiff();

    address[3] memory callee = [address(front), address(tIn), address(front)];
    bytes[3] memory call = [
      abi.encodeCall(IPropAMMFront.payPoolOf, (LISTING)),
      abi.encodeCall(IERC20.transfer, (address(pool), amountIn)),
      abi.encodeCall(
        IPropAMMFront.swapExactInPaid,
        (address(tIn), address(tOut), amountIn, 1, recipient, block.timestamp, LISTING)
      )
    ];
    uint256 n;
    for (uint256 i; i < a.length; ++i) {
      if (a[i].accessor != address(adapter) || a[i].kind == VmSafe.AccountAccessKind.Resume) {
        continue;
      }
      assertLt(n, 3, 'no other call of the adapter');
      assertEq(a[i].account, callee[n], 'callee');
      assertEq(a[i].data, call[n], 'call');
      ++n;
    }
    assertEq(n, 3, 'the read, the payment and the paid call');
  }

  /// @dev In either mode, a refusal after the input landed at the pool reverts the hop with the
  ///      venue's own revert data, which carries the pool's balance at the refusal: the payment had
  ///      landed, and the revert undoes it.
  function test_refusalUndoesPayment(uint256 mode, bool named, bool zeroForOne, uint256 amountIn)
    public
  {
    mode = bound(mode, 0, 1);
    front.setCredit(named);
    door.setRefuse(true);
    front.setRefuse(true);
    (EfficientPropTestToken tIn, EfficientPropTestToken tOut) = _side(zeroForOne);
    amountIn = bound(amountIn, 1, 1e30);
    tIn.mint(address(adapter), amountIn);
    uint256 poolBefore = tIn.balanceOf(address(pool));

    (bool ok, bytes memory ret) = address(adapter)
      .call(
        abi.encodeCall(
          EfficientPropAdapter.executeEfficientProp,
          (_data(mode), amountIn, address(tIn), address(tOut), recipient)
        )
      );

    assertFalse(ok, 'the hop reverts');
    assertEq(
      ret,
      abi.encodeWithSelector(
        EfficientPropMockVenue.Refused.selector, poolBefore + amountIn, recipient
      ),
      'the venue\'s own revert data'
    );
  }

  function test_unknownModeReverts(uint256 mode) public {
    mode = bound(mode, 3, type(uint256).max);
    token0.mint(address(adapter), 1 ether);
    vm.expectRevert(abi.encodeWithSelector(EfficientPropAdapter.UnknownFillMode.selector, mode));
    adapter.executeEfficientProp(_data(mode), 1 ether, address(token0), address(token1), recipient);
  }

  /// @dev Run the hop through `venue` in `mode` and check what every fill shares: the entry the
  ///      mode picks, the venue terms (minimum output 1, this block, the recipient), the quote as
  ///      the output, paid to the recipient, `amountIn` at the pool while the input the adapter
  ///      holds beside it stays, and no approval left on the door or the front.
  function _checkFill(
    EfficientPropMockVenue venue,
    uint256 mode,
    bytes32 entry,
    uint256 amountIn,
    bool zeroForOne
  ) internal {
    (EfficientPropTestToken tIn, EfficientPropTestToken tOut) = _side(zeroForOne);
    amountIn = zeroForOne ? bound(amountIn, 1, 1e9 ether) : bound(amountIn, 3000, 1e12 ether);
    tIn.mint(address(adapter), amountIn + HELD);
    uint256 recipientBefore = tOut.balanceOf(recipient);
    uint256 poolBefore = tIn.balanceOf(address(pool));
    uint256 expected = venue.quote(address(tIn), amountIn);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeEfficientProp(_data(mode), amountIn, address(tIn), address(tOut), recipient);

    assertEq(venue.lastEntry(), entry, 'entry');
    assertEq(venue.lastTerms(), abi.encode(1, block.timestamp, recipient), 'venue terms');
    assertEq(amountUnused, 0, 'nothing unused');
    assertEq(amountOut, expected, 'output is the quote');
    assertEq(tOut.balanceOf(recipient) - recipientBefore, amountOut, 'amountOut was paid');
    assertEq(tIn.balanceOf(address(adapter)), HELD, 'amountIn spent, no more');
    assertEq(tIn.balanceOf(address(pool)) - poolBefore, amountIn, 'pool took the input');
    assertEq(tIn.allowance(address(adapter), address(door)), 0, 'no approval on the door');
    assertEq(tIn.allowance(address(adapter), address(front)), 0, 'no approval on the front');
  }

  function _side(bool zeroForOne)
    internal
    view
    returns (EfficientPropTestToken, EfficientPropTestToken)
  {
    return zeroForOne ? (token0, token1) : (token1, token0);
  }

  function _data(uint256 mode) internal view returns (bytes memory) {
    return abi.encode(address(door), address(front), uint256(LISTING), mode);
  }
}
