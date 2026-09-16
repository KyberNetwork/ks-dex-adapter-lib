// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2026 Everlong Labs Limited
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import './DelegatecallExecutor.sol';
import 'src/adapters/everlong-flamm/EverlongFlammAdapter.sol';

import {ERC20} from 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';

contract MockERC20 is ERC20 {
  constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @dev A pool with configurable getters and settlement: it takes `pullAmount` of the input
/// with transferFrom, mints `refundAmount` of the input back to the caller, pays `outAmount`
/// to `to`, and REPORTS `reportAmount` as used, independently of what it did. It also
/// records which entry the adapter dispatched to.
contract MockFlamm {
  address public asset;
  address public loanAsset;

  uint256 public pullAmount;
  uint256 public reportAmount;
  uint256 public refundAmount;
  uint256 public outAmount;

  bytes4 public lastEntry;
  bytes public lastArgs;

  constructor(address asset_, address loanAsset_) {
    asset = asset_;
    loanAsset = loanAsset_;
  }

  function relabel(address asset_, address loanAsset_) external {
    asset = asset_;
    loanAsset = loanAsset_;
  }

  function configure(uint256 pull_, uint256 report_, uint256 refund_, uint256 out_) external {
    pullAmount = pull_;
    reportAmount = report_;
    refundAmount = refund_;
    outAmount = out_;
  }

  function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address to,
    uint256 deadline
  ) external returns (uint256, uint256) {
    lastEntry = this.swap.selector;
    lastArgs = abi.encode(tokenIn, tokenOut, amountIn, minAmountOut, to, deadline);
    return _settle(tokenIn, tokenOut, to);
  }

  function leverUp(uint256 poolAssetIn, uint256 minLoanOut, address to, uint256 deadline)
    external
    returns (uint256, uint256)
  {
    lastEntry = this.leverUp.selector;
    lastArgs = abi.encode(poolAssetIn, minLoanOut, to, deadline);
    return _settle(asset, loanAsset, to);
  }

  function leverDown(uint256 loanIn, uint256 minPoolOut, address to, uint256 deadline)
    external
    returns (uint256, uint256)
  {
    lastEntry = this.leverDown.selector;
    lastArgs = abi.encode(loanIn, minPoolOut, to, deadline);
    return _settle(loanAsset, asset, to);
  }

  function _settle(address tokenIn, address tokenOut, address to)
    internal
    returns (uint256, uint256)
  {
    if (pullAmount != 0) {
      IERC20(tokenIn).transferFrom(msg.sender, address(this), pullAmount);
    }
    if (refundAmount != 0) MockERC20(tokenIn).mint(msg.sender, refundAmount);
    if (outAmount != 0) MockERC20(tokenOut).mint(to, outAmount);
    return (reportAmount, outAmount);
  }
}

/// @dev A pool that reenters the adapter from inside the swap, then takes whatever the
/// adapter still lets it take and claims the outer input as used. The adapter is stateless,
/// so the reentrant call is just a second, independent fill attempt.
contract ReentrantFlamm {
  address public asset;
  address public loanAsset;
  bytes public payload;
  uint256 public entries;
  bool public innerSucceeded;

  constructor(address asset_, address loanAsset_) {
    asset = asset_;
    loanAsset = loanAsset_;
  }

  function arm(bytes memory payload_) external {
    payload = payload_;
  }

  function swap(address tokenIn, address, uint256 amountIn, uint256, address, uint256)
    external
    returns (uint256, uint256)
  {
    if (entries++ == 0) {
      (innerSucceeded,) = msg.sender.call(payload);
    }
    uint256 take = IERC20(tokenIn).balanceOf(msg.sender);
    uint256 allowed = IERC20(tokenIn).allowance(msg.sender, address(this));
    if (allowed < take) take = allowed;
    if (take != 0) IERC20(tokenIn).transferFrom(msg.sender, address(this), take);
    return (amountIn, 0);
  }
}

/// @dev A pool that spends the outer allowance, then reenters the adapter for a SECOND,
/// honestly reported fill over the adapter's residual balance, and finally reports either
/// the outer input alone or everything that left the adapter.
contract DrainingFlamm {
  address public asset;
  address public loanAsset;
  bytes public payload;
  bool public claimEverything;
  uint256 public entries;

  constructor(address asset_, address loanAsset_) {
    asset = asset_;
    loanAsset = loanAsset_;
  }

  function arm(bytes memory payload_, bool claimEverything_) external {
    payload = payload_;
    claimEverything = claimEverything_;
  }

  function swap(address tokenIn, address, uint256 amountIn, uint256, address, uint256)
    external
    returns (uint256, uint256)
  {
    IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    if (entries++ != 0) return (amountIn, 0);
    (bool ok, bytes memory ret) = msg.sender.call(payload);
    require(ok, 'the reentrant fill must settle for the outer check to be isolated');
    (uint256 innerUnused,) = abi.decode(ret, (uint256, uint256));
    require(innerUnused == 0);
    uint256 innerIn = IERC20(tokenIn).balanceOf(address(this)) - amountIn;
    return (claimEverything ? amountIn + innerIn : amountIn, 0);
  }
}

/// @notice Adversarial cases on local mocks (no fork). The adapter takes the pool address from
/// `data`, so the exposure is (a) a crafted pool pulling more than the call's input and (b) a
/// pool whose report disagrees with what actually moved, which would hand the route a wrong
/// `amountUnused`. Every case must either settle with the report matching the balance delta
/// or revert; no allowance may outlive the call. What the adapter guarantees is per call: the
/// pull is bounded by that call's allowance and its report must equal its balance delta. A
/// balance the adapter holds beyond the call's input is NOT protected — any direct call with a
/// pool that pulls and reports it honestly settles.
contract EverlongFlammAdapterAdversarialTest is Test {
  using TokenHelper for address;

  uint256 constant VENUE_SWAP = 0;
  uint256 constant VENUE_LEVERAGE = 1;
  uint256 constant AMOUNT_IN = 1e8;

  MockERC20 poolAsset;
  MockERC20 loanAsset;
  MockERC20 other;
  EverlongFlammAdapter adapter;
  address recipient = makeAddr('recipient');

  function setUp() public {
    poolAsset = new MockERC20('BTC');
    loanAsset = new MockERC20('USD');
    other = new MockERC20('OTHER');
    adapter = new EverlongFlammAdapter();
  }

  function _pool() internal returns (MockFlamm) {
    return new MockFlamm(address(poolAsset), address(loanAsset));
  }

  function _data(address pool, uint256 venue) internal pure returns (bytes memory) {
    return abi.encode(pool, venue);
  }

  // ------------------------------------------------------------------ honest settlement

  /// @dev Each (venue, direction) reaches its own pool entry with the route's amount, a
  /// venue-level minimum of 1, the recipient and the current block as deadline.
  function test_dispatch() public {
    MockFlamm pool = _pool();
    pool.configure(AMOUNT_IN, AMOUNT_IN, 0, 7);

    poolAsset.mint(address(adapter), AMOUNT_IN);
    adapter.executeEverlongFlamm(
      _data(address(pool), VENUE_SWAP), AMOUNT_IN, address(poolAsset), address(loanAsset), recipient
    );
    assertEq(pool.lastEntry(), MockFlamm.swap.selector);
    assertEq(
      pool.lastArgs(),
      abi.encode(
        address(poolAsset), address(loanAsset), AMOUNT_IN, uint256(1), recipient, block.timestamp
      )
    );

    loanAsset.mint(address(adapter), AMOUNT_IN);
    adapter.executeEverlongFlamm(
      _data(address(pool), VENUE_SWAP), AMOUNT_IN, address(loanAsset), address(poolAsset), recipient
    );
    assertEq(pool.lastEntry(), MockFlamm.swap.selector);
    assertEq(
      pool.lastArgs(),
      abi.encode(
        address(loanAsset), address(poolAsset), AMOUNT_IN, uint256(1), recipient, block.timestamp
      )
    );

    poolAsset.mint(address(adapter), AMOUNT_IN);
    adapter.executeEverlongFlamm(
      _data(address(pool), VENUE_LEVERAGE),
      AMOUNT_IN,
      address(poolAsset),
      address(loanAsset),
      recipient
    );
    assertEq(pool.lastEntry(), MockFlamm.leverUp.selector);
    assertEq(pool.lastArgs(), abi.encode(AMOUNT_IN, uint256(1), recipient, block.timestamp));

    loanAsset.mint(address(adapter), AMOUNT_IN);
    adapter.executeEverlongFlamm(
      _data(address(pool), VENUE_LEVERAGE),
      AMOUNT_IN,
      address(loanAsset),
      address(poolAsset),
      recipient
    );
    assertEq(pool.lastEntry(), MockFlamm.leverDown.selector);
    assertEq(pool.lastArgs(), abi.encode(AMOUNT_IN, uint256(1), recipient, block.timestamp));
  }

  /// @dev A truthful partial fill: the remainder is reported, stays in the adapter, and the
  /// unspent allowance is cleared.
  function test_partialFillClearsAllowance(uint256 used) public {
    used = bound(used, 0, AMOUNT_IN);
    MockFlamm pool = _pool();
    pool.configure(used, used, 0, 5);
    loanAsset.mint(address(adapter), AMOUNT_IN);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongFlamm(
      _data(address(pool), VENUE_LEVERAGE),
      AMOUNT_IN,
      address(loanAsset),
      address(poolAsset),
      recipient
    );

    assertEq(amountUnused, AMOUNT_IN - used);
    assertEq(amountOut, 5);
    assertEq(address(loanAsset).balanceOf(address(adapter)), amountUnused);
    assertEq(address(poolAsset).balanceOf(recipient), 5);
    assertEq(loanAsset.allowance(address(adapter), address(pool)), 0, 'no standing allowance');
  }

  // ------------------------------------------------------------------ lying pools

  function _expectMisreport(MockFlamm pool, uint256 venue) internal {
    poolAsset.mint(address(adapter), AMOUNT_IN);
    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_Misreport.selector);
    adapter.executeEverlongFlamm(
      _data(address(pool), venue), AMOUNT_IN, address(poolAsset), address(loanAsset), recipient
    );
  }

  /// @dev Takes the whole input but claims less: the route would count stolen input as
  /// unused.
  function test_underReportedUse_misreport(uint256 venue) public {
    venue = bound(venue, VENUE_SWAP, VENUE_LEVERAGE);
    MockFlamm pool = _pool();
    pool.configure(AMOUNT_IN, AMOUNT_IN - 1, 0, 1);
    _expectMisreport(pool, venue);
  }

  /// @dev Claims more than `amountIn`: `amountIn - used` would underflow the route.
  function test_overReportedUse_misreport(uint256 venue) public {
    venue = bound(venue, VENUE_SWAP, VENUE_LEVERAGE);
    MockFlamm pool = _pool();
    pool.configure(AMOUNT_IN, AMOUNT_IN + 1, 0, 1);
    _expectMisreport(pool, venue);
  }

  /// @dev Reports a full fill while pulling nothing.
  function test_pullsNothingReportsFull_misreport(uint256 venue) public {
    venue = bound(venue, VENUE_SWAP, VENUE_LEVERAGE);
    MockFlamm pool = _pool();
    pool.configure(0, AMOUNT_IN, 0, 1);
    _expectMisreport(pool, venue);
  }

  /// @dev Hands input back so the adapter ends with MORE than it started with.
  function test_returnsInput_misreport(uint256 venue) public {
    venue = bound(venue, VENUE_SWAP, VENUE_LEVERAGE);
    MockFlamm pool = _pool();
    pool.configure(0, 0, 1, 1);
    _expectMisreport(pool, venue);

    MockFlamm pool2 = _pool();
    pool2.configure(AMOUNT_IN, 0, AMOUNT_IN + 1, 1);
    _expectMisreport(pool2, venue);
  }

  // ------------------------------------------------------------------ reentrancy

  /// @dev A reentrant pool that settles both calls, each reporting `AMOUNT_IN`, pulls one input
  /// in total: both calls approve the same spender and the inner one clears the allowance the
  /// outer pull would have used. A residual beyond the input sits in the adapter throughout, so
  /// "nothing more" is measured, and it is still there afterwards with no allowance left.
  function test_reentrantDoubleSettleTakesOneInput() public {
    uint256 residual = 3e8;
    ReentrantFlamm pool = new ReentrantFlamm(address(poolAsset), address(loanAsset));
    bytes memory data = _data(address(pool), VENUE_SWAP);
    poolAsset.mint(address(adapter), AMOUNT_IN + residual);
    pool.arm(
      abi.encodeCall(
        adapter.executeEverlongFlamm,
        (data, AMOUNT_IN, address(poolAsset), address(loanAsset), recipient)
      )
    );

    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongFlamm(
      data, AMOUNT_IN, address(poolAsset), address(loanAsset), recipient
    );

    assertEq(pool.entries(), 2, 'the reentrant attempt ran');
    assertTrue(pool.innerSucceeded(), 'the reentrant fill settled');
    assertEq(amountUnused, 0);
    assertEq(amountOut, 0);
    assertEq(poolAsset.balanceOf(address(pool)), AMOUNT_IN, 'took exactly the input, nothing more');
    assertEq(poolAsset.balanceOf(address(adapter)), residual, 'the residual was not pulled');
    assertEq(poolAsset.allowance(address(adapter), address(pool)), 0, 'no standing allowance');
  }

  /// @dev With a residual balance in the adapter, a pool that drains it through a reentrant
  /// fill cannot settle the OUTER route: claiming only the outer input breaks the balance
  /// delta, and claiming everything exceeds `amountIn`. This does not protect the residual:
  /// the inner call itself settles (DrainingFlamm requires it), so the same call made directly
  /// rather than reentrantly moves the residual out.
  function test_reentrantDrainRevertsOuterRoute(bool claimEverything) public {
    uint256 residual = 3e8;
    DrainingFlamm pool = new DrainingFlamm(address(poolAsset), address(loanAsset));
    bytes memory data = _data(address(pool), VENUE_SWAP);
    poolAsset.mint(address(adapter), AMOUNT_IN + residual);
    pool.arm(
      abi.encodeCall(
        adapter.executeEverlongFlamm,
        (data, residual, address(poolAsset), address(loanAsset), recipient)
      ),
      claimEverything
    );

    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_Misreport.selector);
    adapter.executeEverlongFlamm(data, AMOUNT_IN, address(poolAsset), address(loanAsset), recipient);

    assertEq(poolAsset.balanceOf(address(adapter)), AMOUNT_IN + residual);
    assertEq(poolAsset.allowance(address(adapter), address(pool)), 0);
  }

  // ------------------------------------------------------------------ pair binding

  /// @dev The pair comes from the pool's getters, so a pool that relabels its legs refuses
  /// the route by name rather than settling a pair it does not trade.
  function test_relabelledPair_tokenMismatch(uint256 venue) public {
    venue = bound(venue, VENUE_SWAP, VENUE_LEVERAGE);
    MockFlamm pool = _pool();
    pool.configure(AMOUNT_IN, AMOUNT_IN, 0, 1);
    poolAsset.mint(address(adapter), AMOUNT_IN);
    bytes memory data = _data(address(pool), venue);

    pool.relabel(address(poolAsset), address(other));
    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_TokenMismatch.selector);
    adapter.executeEverlongFlamm(data, AMOUNT_IN, address(poolAsset), address(loanAsset), recipient);

    pool.relabel(address(other), address(loanAsset));
    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_TokenMismatch.selector);
    adapter.executeEverlongFlamm(data, AMOUNT_IN, address(poolAsset), address(loanAsset), recipient);

    pool.relabel(address(poolAsset), address(poolAsset));
    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_TokenMismatch.selector);
    adapter.executeEverlongFlamm(data, AMOUNT_IN, address(poolAsset), address(loanAsset), recipient);

    assertEq(poolAsset.balanceOf(address(adapter)), AMOUNT_IN, 'a refused route spends nothing');
  }

  /// @dev Neither leg may be native.
  function test_nativeUnsupported() public {
    MockFlamm pool = new MockFlamm(TokenHelper.NATIVE_ADDRESS, address(loanAsset));
    bytes memory data = _data(address(pool), VENUE_SWAP);

    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_NativeUnsupported.selector);
    adapter.executeEverlongFlamm(
      data, AMOUNT_IN, TokenHelper.NATIVE_ADDRESS, address(loanAsset), recipient
    );
    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_NativeUnsupported.selector);
    adapter.executeEverlongFlamm(
      data, AMOUNT_IN, address(loanAsset), TokenHelper.NATIVE_ADDRESS, recipient
    );
    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_NativeUnsupported.selector);
    adapter.executeEverlongFlamm(data, AMOUNT_IN, address(0), address(loanAsset), recipient);
  }

  /// @dev `msg.value` is not a refusal: the executor DELEGATECALLs adapters, so an ERC-20 hop
  /// of a native-input route carries the route's value. Called directly and delegatecalled,
  /// an ERC-20 fill with value on the frame settles like one without, in both venues.
  function test_erc20HopWithValue_settles(uint256 venue) public {
    venue = bound(venue, VENUE_SWAP, VENUE_LEVERAGE);
    MockFlamm pool = _pool();
    pool.configure(AMOUNT_IN, AMOUNT_IN, 0, 7);
    bytes memory data = _data(address(pool), venue);
    vm.deal(address(this), 2);

    poolAsset.mint(address(adapter), AMOUNT_IN);
    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongFlamm{value: 1}(
      data, AMOUNT_IN, address(poolAsset), address(loanAsset), recipient
    );
    assertEq(amountUnused, 0);
    assertEq(amountOut, 7);
    assertEq(address(loanAsset).balanceOf(recipient), 7);

    DelegatecallExecutor executor = new DelegatecallExecutor();
    poolAsset.mint(address(executor), AMOUNT_IN);
    (amountUnused, amountOut) = executor.execute{value: 1}(
      address(adapter), data, AMOUNT_IN, address(poolAsset), address(loanAsset), recipient
    );
    assertEq(amountUnused, 0);
    assertEq(amountOut, 7);
    assertEq(address(loanAsset).balanceOf(recipient), 14);
    assertEq(poolAsset.balanceOf(address(executor)), 0, 'pulled from the executor');
    assertEq(poolAsset.allowance(address(executor), address(pool)), 0, 'no standing allowance');
    assertEq(address(executor).balance, 1, 'value untouched');
  }

  /// @dev `data` shorter than two words is refused by name. `decodeUint256(1)` reads calldata
  /// unchecked, so a one-word blob would otherwise read whatever follows it — zero at the end
  /// of the calldata — as venue 0 and silently run the swap venue.
  function test_shortData_reverts() public {
    MockFlamm pool = _pool();
    pool.configure(AMOUNT_IN, AMOUNT_IN, 0, 7);
    poolAsset.mint(address(adapter), AMOUNT_IN);

    bytes[3] memory blobs = [
      abi.encodePacked(bytes32(uint256(uint160(address(pool))))),
      abi.encodePacked(bytes31(bytes32(uint256(uint160(address(pool)))))),
      bytes('')
    ];
    for (uint256 i; i < blobs.length; i++) {
      assertLt(blobs[i].length, 64);
      vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_InvalidData.selector);
      adapter.executeEverlongFlamm(
        blobs[i], AMOUNT_IN, address(poolAsset), address(loanAsset), recipient
      );
    }

    assertEq(pool.lastEntry(), bytes4(0), 'no venue was reached');
    assertEq(poolAsset.balanceOf(address(adapter)), AMOUNT_IN, 'a refused route spends nothing');
    assertEq(poolAsset.allowance(address(adapter), address(pool)), 0, 'no standing allowance');
  }

  function test_unknownVenue(uint256 venue) public {
    venue = bound(venue, VENUE_LEVERAGE + 1, type(uint256).max);
    MockFlamm pool = _pool();
    poolAsset.mint(address(adapter), AMOUNT_IN);
    vm.expectRevert(EverlongFlammAdapter.EverlongFlammAdapter_UnknownVenue.selector);
    adapter.executeEverlongFlamm(
      _data(address(pool), venue), AMOUNT_IN, address(poolAsset), address(loanAsset), recipient
    );
  }
}
