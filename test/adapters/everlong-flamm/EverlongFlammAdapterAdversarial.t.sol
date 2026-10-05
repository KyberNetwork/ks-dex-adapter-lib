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

/// @dev A pool with a configurable fill: it takes `pullAmount` of the input with transferFrom,
/// pays `outAmount` to `to`, and reports the pull as used. It also records which entry the
/// adapter dispatched to.
contract MockFlamm {
  address public asset;
  address public loanAsset;

  uint256 public pullAmount;
  uint256 public outAmount;

  bytes4 public lastEntry;
  bytes public lastArgs;

  constructor(address asset_, address loanAsset_) {
    asset = asset_;
    loanAsset = loanAsset_;
  }

  function configure(uint256 pull_, uint256 out_) external {
    pullAmount = pull_;
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
    if (outAmount != 0) MockERC20(tokenOut).mint(to, outAmount);
    return (pullAmount, outAmount);
  }
}

/// @notice Adversarial cases on local mocks (no fork). The adapter takes the pool address and
/// the kind from `data`, so these pin what the adapter itself does with them: each kind reaches
/// its own pool entry with the route's amount, a venue-level minimum of 1, the recipient and the
/// current block as deadline, and `amountUnused` is the pool's own `amountIn - amountInUsed`.
/// The amounts the pool reports are trusted; what a pool may move is bounded by the allowance
/// this call sets, and the route's minReturn is enforced above the adapter.
contract EverlongFlammAdapterAdversarialTest is Test {
  using TokenHelper for address;

  uint256 constant KIND_SWAP = 0;
  uint256 constant KIND_LEVER_UP = 1;
  uint256 constant KIND_LEVER_DOWN = 2;
  uint256 constant AMOUNT_IN = 1e8;

  MockERC20 poolAsset;
  MockERC20 loanAsset;
  EverlongFlammAdapter adapter;
  address recipient = makeAddr('recipient');

  function setUp() public {
    poolAsset = new MockERC20('BTC');
    loanAsset = new MockERC20('USD');
    adapter = new EverlongFlammAdapter();
  }

  function _pool() internal returns (MockFlamm) {
    return new MockFlamm(address(poolAsset), address(loanAsset));
  }

  function _data(address pool, uint256 kind) internal pure returns (bytes memory) {
    return abi.encode(pool, kind);
  }

  // ------------------------------------------------------------------ honest settlement

  /// @dev Each kind reaches its own pool entry with the route's amount, a venue-level minimum
  /// of 1, the recipient and the current block as deadline.
  function test_dispatch() public {
    MockFlamm pool = _pool();
    pool.configure(AMOUNT_IN, 7);

    poolAsset.mint(address(adapter), AMOUNT_IN);
    adapter.executeEverlongFlamm(
      _data(address(pool), KIND_SWAP), AMOUNT_IN, address(poolAsset), address(loanAsset), recipient
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
      _data(address(pool), KIND_SWAP), AMOUNT_IN, address(loanAsset), address(poolAsset), recipient
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
      _data(address(pool), KIND_LEVER_UP),
      AMOUNT_IN,
      address(poolAsset),
      address(loanAsset),
      recipient
    );
    assertEq(pool.lastEntry(), MockFlamm.leverUp.selector);
    assertEq(pool.lastArgs(), abi.encode(AMOUNT_IN, uint256(1), recipient, block.timestamp));

    loanAsset.mint(address(adapter), AMOUNT_IN);
    adapter.executeEverlongFlamm(
      _data(address(pool), KIND_LEVER_DOWN),
      AMOUNT_IN,
      address(loanAsset),
      address(poolAsset),
      recipient
    );
    assertEq(pool.lastEntry(), MockFlamm.leverDown.selector);
    assertEq(pool.lastArgs(), abi.encode(AMOUNT_IN, uint256(1), recipient, block.timestamp));
  }

  /// @dev A partial fill: the remainder is reported through amountUnused and stays in the adapter.
  function test_partialFillReportsRemainder(uint256 used) public {
    used = bound(used, 0, AMOUNT_IN);
    MockFlamm pool = _pool();
    pool.configure(used, 5);
    loanAsset.mint(address(adapter), AMOUNT_IN);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeEverlongFlamm(
      _data(address(pool), KIND_LEVER_DOWN),
      AMOUNT_IN,
      address(loanAsset),
      address(poolAsset),
      recipient
    );

    assertEq(amountUnused, AMOUNT_IN - used);
    assertEq(amountOut, 5);
    assertEq(address(loanAsset).balanceOf(address(adapter)), amountUnused);
    assertEq(address(poolAsset).balanceOf(recipient), 5);
  }

  /// @dev `msg.value` is not a refusal: the executor DELEGATECALLs adapters, so an ERC-20 hop
  /// of a native-input route carries the route's value. Called directly and delegatecalled,
  /// an ERC-20 fill with value on the frame settles like one without, in both venues.
  function test_erc20HopWithValue_settles(uint256 kind) public {
    kind = bound(kind, KIND_SWAP, KIND_LEVER_UP);
    MockFlamm pool = _pool();
    pool.configure(AMOUNT_IN, 7);
    bytes memory data = _data(address(pool), kind);
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
    assertEq(address(executor).balance, 1, 'value untouched');
  }
}
