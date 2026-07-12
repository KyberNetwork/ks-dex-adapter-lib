// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/ringswap-backing/RingSwapBackingAdapter.sol';

contract RingSwapBackingAdapterMockToken {
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;

  function mint(address to, uint256 amount) public {
    balanceOf[to] += amount;
  }

  function burn(address from, uint256 amount) external {
    balanceOf[from] -= amount;
  }

  function approve(address spender, uint256 amount) external returns (bool) {
    require(amount == 0 || allowance[msg.sender][spender] == 0, 'RESET_REQUIRED');
    allowance[msg.sender][spender] = amount;
    return true;
  }

  function transfer(address to, uint256 amount) public returns (bool) {
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) public returns (bool) {
    uint256 allowed = allowance[from][msg.sender];
    if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
    balanceOf[from] -= amount;
    balanceOf[to] += amount;
    return true;
  }
}

contract RingSwapBackingAdapterMockWrapper is RingSwapBackingAdapterMockToken {
  RingSwapBackingAdapterMockToken public immutable token;

  constructor(RingSwapBackingAdapterMockToken token_) {
    token = token_;
  }

  function wrapTo(uint256 amount, address recipient) external returns (uint256 wrapped) {
    token.transferFrom(msg.sender, address(this), amount);
    mint(recipient, amount);
    return amount;
  }

  function unwrapTo(uint256 amount, address recipient) external returns (uint256 unwrapped) {
    balanceOf[msg.sender] -= amount;
    token.transfer(recipient, amount);
    return amount;
  }
}

contract RingSwapBackingAdapterMockPair {
  RingSwapBackingAdapterMockWrapper public immutable token0;
  RingSwapBackingAdapterMockWrapper public immutable token1;
  uint112 public reserve0;
  uint112 public reserve1;

  constructor(
    RingSwapBackingAdapterMockWrapper token0_,
    RingSwapBackingAdapterMockWrapper token1_
  ) {
    token0 = token0_;
    token1 = token1_;
  }

  function sync() external {
    reserve0 = uint112(token0.balanceOf(address(this)));
    reserve1 = uint112(token1.balanceOf(address(this)));
  }

  function getReserves() external view returns (uint112, uint112, uint32) {
    return (reserve0, reserve1, uint32(block.timestamp));
  }

  function swap(uint256 amount0Out, uint256 amount1Out, address recipient, bytes calldata)
    external
  {
    if (amount0Out != 0) token0.transfer(recipient, amount0Out);
    if (amount1Out != 0) token1.transfer(recipient, amount1Out);
    reserve0 = uint112(token0.balanceOf(address(this)));
    reserve1 = uint112(token1.balanceOf(address(this)));
  }
}

contract RingSwapBackingAdapterMockRouter is IFewBackingAwareV2Router {
  address public immutable origin0;
  address public immutable origin1;
  address public immutable pair;
  address public immutable wrapper0;
  address public immutable wrapper1;
  bool public lieAboutOutput;

  constructor(
    address origin0_,
    address origin1_,
    address pair_,
    address wrapper0_,
    address wrapper1_
  ) {
    origin0 = origin0_;
    origin1 = origin1_;
    pair = pair_;
    wrapper0 = wrapper0_;
    wrapper1 = wrapper1_;
  }

  function setLieAboutOutput(bool lie) external {
    lieAboutOutput = lie;
  }

  function routeConfig() external view returns (address, address, address, address, address) {
    return (pair, wrapper0, wrapper1, origin0, origin1);
  }

  function swapExactInput(
    address originIn,
    uint256 amountIn,
    uint256,
    address recipient,
    uint256 deadline
  ) external returns (uint256 amountOut, bool) {
    require(block.timestamp <= deadline, 'DEADLINE');
    address originOut = originIn == origin0 ? origin1 : origin0;
    RingSwapBackingAdapterMockToken(originIn).transferFrom(msg.sender, address(this), amountIn);
    amountOut = amountIn * 2;
    RingSwapBackingAdapterMockToken(originOut).mint(recipient, amountOut);
    if (lieAboutOutput) amountOut++;
    return (amountOut, true);
  }
}

contract RingSwapBackingAdapterTest is Test {
  uint256 internal constant RESERVE = 10_000_000;

  RingSwapBackingAdapter internal adapter;
  RingSwapBackingAdapterMockToken internal token0;
  RingSwapBackingAdapterMockToken internal token1;
  RingSwapBackingAdapterMockToken internal unrelated;
  RingSwapBackingAdapterMockWrapper internal wrapper0;
  RingSwapBackingAdapterMockWrapper internal wrapper1;
  RingSwapBackingAdapterMockPair internal pair;
  RingSwapBackingAdapterMockRouter internal router;

  address internal recipient = makeAddr('recipient');

  function setUp() public {
    adapter = new RingSwapBackingAdapter();
    token0 = new RingSwapBackingAdapterMockToken();
    token1 = new RingSwapBackingAdapterMockToken();
    unrelated = new RingSwapBackingAdapterMockToken();
    wrapper0 = new RingSwapBackingAdapterMockWrapper(token0);
    wrapper1 = new RingSwapBackingAdapterMockWrapper(token1);
    pair = new RingSwapBackingAdapterMockPair(wrapper0, wrapper1);
    router = new RingSwapBackingAdapterMockRouter(
      address(token0), address(token1), address(pair), address(wrapper0), address(wrapper1)
    );
    _seed(token0, wrapper0);
    _seed(token1, wrapper1);
    pair.sync();
  }

  function test_executeRingSwapBacking_hotPathUsesOriginalPair(bool zeroForOne) public {
    address tokenIn = zeroForOne ? address(token0) : address(token1);
    address tokenOut = zeroForOne ? address(token1) : address(token0);
    address wrapperIn = zeroForOne ? address(wrapper0) : address(wrapper1);
    uint256 amountIn = 1_000_000;
    uint256 expected = _amountOut(amountIn, RESERVE, RESERVE);
    RingSwapBackingAdapterMockToken(tokenIn).mint(address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeRingSwapBacking(
      abi.encode(address(router), false), amountIn, tokenIn, tokenOut, recipient
    );

    assertEq(amountUnused, 0);
    assertEq(amountOut, expected);
    assertEq(RingSwapBackingAdapterMockToken(tokenOut).balanceOf(recipient), expected);
    assertEq(RingSwapBackingAdapterMockToken(tokenIn).allowance(address(adapter), wrapperIn), 0);
  }

  function test_executeRingSwapBacking_recallPathUsesRouter(bool zeroForOne) public {
    address tokenIn = zeroForOne ? address(token0) : address(token1);
    address tokenOut = zeroForOne ? address(token1) : address(token0);
    uint256 amountIn = 1_000_000;
    RingSwapBackingAdapterMockToken(tokenIn).mint(address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeRingSwapBacking(
      abi.encode(address(router), true), amountIn, tokenIn, tokenOut, recipient
    );

    assertEq(amountUnused, 0);
    assertEq(amountOut, amountIn * 2);
    assertEq(
      RingSwapBackingAdapterMockToken(tokenIn).allowance(address(adapter), address(router)), 0
    );
  }

  function test_executeRingSwapBacking_hotPathFallsBackToRouterWhenBackingTurnsCold() public {
    token1.burn(address(wrapper1), RESERVE);
    token0.mint(address(adapter), 1_000_000);
    (, uint256 amountOut) = adapter.executeRingSwapBacking(
      abi.encode(address(router), false), 1_000_000, address(token0), address(token1), recipient
    );

    assertEq(amountOut, 2_000_000);
    assertEq(token1.balanceOf(recipient), amountOut);
    assertEq(token0.allowance(address(adapter), address(router)), 0);
  }

  function test_executeRingSwapBacking_rejectsWrongTokenPair() public {
    token0.mint(address(adapter), 1_000_000);
    vm.expectRevert(RingSwapBackingAdapter.InvalidTokenPair.selector);
    adapter.executeRingSwapBacking(
      abi.encode(address(router), true), 1_000_000, address(token0), address(unrelated), recipient
    );
  }

  function test_executeRingSwapBacking_rejectsMalformedDataAndMode() public {
    token0.mint(address(adapter), 1_000_000);
    vm.expectRevert(RingSwapBackingAdapter.InvalidData.selector);
    adapter.executeRingSwapBacking(
      abi.encode(address(router)), 1_000_000, address(token0), address(token1), recipient
    );
    vm.expectRevert(RingSwapBackingAdapter.InvalidData.selector);
    adapter.executeRingSwapBacking(
      abi.encode(address(router), uint256(2)),
      1_000_000,
      address(token0),
      address(token1),
      recipient
    );
  }

  function test_executeRingSwapBacking_rejectsNativeToken() public {
    vm.expectRevert(RingSwapBackingAdapter.NativeTokenUnsupported.selector);
    adapter.executeRingSwapBacking(
      abi.encode(address(router), true),
      1_000_000,
      0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
      address(token1),
      recipient
    );

    token0.mint(address(adapter), 1_000_000);
    vm.deal(address(this), 1 ether);
    vm.expectRevert(RingSwapBackingAdapter.NativeTokenUnsupported.selector);
    adapter.executeRingSwapBacking{value: 1}(
      abi.encode(address(router), false), 1_000_000, address(token0), address(token1), recipient
    );
  }

  function test_executeRingSwapBacking_rejectsMisreportedOutput() public {
    router.setLieAboutOutput(true);
    token0.mint(address(adapter), 1_000_000);
    vm.expectRevert(
      abi.encodeWithSelector(RingSwapBackingAdapter.OutputMismatch.selector, 2_000_001, 2_000_000)
    );
    adapter.executeRingSwapBacking(
      abi.encode(address(router), true), 1_000_000, address(token0), address(token1), recipient
    );
  }

  function _seed(RingSwapBackingAdapterMockToken origin, RingSwapBackingAdapterMockWrapper wrapper)
    internal
  {
    origin.mint(address(this), RESERVE);
    origin.approve(address(wrapper), RESERVE);
    wrapper.wrapTo(RESERVE, address(pair));
  }

  function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut)
    internal
    pure
    returns (uint256)
  {
    uint256 amountInWithFee = amountIn * 997;
    return amountInWithFee * reserveOut / (reserveIn * 1000 + amountInWithFee);
  }
}
