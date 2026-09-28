// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';
import 'src/adapters/uscore/USCoreAdapter.sol';

contract USCoreTestToken is ERC20 {
  constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

contract USCoreTestPool is IUSCorePool {
  USCoreTestToken public token0;
  USCoreTestToken public token1;
  bytes32 public lastCode;
  address public lastSender;
  uint256 public lastDeadline;
  error Expired();

  constructor(USCoreTestToken a, USCoreTestToken b) {
    token0 = a;
    token1 = b;
  }

  function swapExactIn(
    address tokenIn,
    uint256 amountIn,
    uint256 minOut,
    address to,
    uint256 deadline,
    bytes32 refCode
  ) external returns (uint256 amountOut) {
    if (block.timestamp > deadline) revert Expired();
    require(tokenIn == address(token0) || tokenIn == address(token1), 'token');
    lastCode = refCode;
    lastSender = msg.sender;
    lastDeadline = deadline;
    amountOut = amountIn * 99 / 100;
    require(amountOut >= minOut, 'minOut');
    ERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
    (tokenIn == address(token0) ? token1 : token0).transfer(to, amountOut);
  }
}

contract USCoreAdapterTest is Test {
  USCoreAdapter adapter;
  USCoreTestToken a;
  USCoreTestToken b;
  USCoreTestPool pool;
  address recipient = address(0xBEEF);

  function setUp() public {
    adapter = new USCoreAdapter();
    a = new USCoreTestToken('A');
    b = new USCoreTestToken('B');
    pool = new USCoreTestPool(a, b);
    a.mint(address(pool), 1_000_000e18);
    b.mint(address(pool), 1_000_000e18);
  }

  function testFuzz_ExactInputBothDirections(uint256 amountIn, bool reverse, bytes32 code) public {
    amountIn = bound(amountIn, 100, 1000e18);
    USCoreTestToken input = reverse ? b : a;
    USCoreTestToken output = reverse ? a : b;
    input.mint(address(adapter), amountIn);
    uint256 deadline = block.timestamp + 300;
    (uint256 unused, uint256 out) = adapter.executeUSCore(
      abi.encode(address(pool), deadline, code),
      amountIn,
      address(input),
      address(output),
      recipient
    );
    assertEq(unused, 0);
    assertEq(out, amountIn * 99 / 100);
    assertEq(output.balanceOf(recipient), out);
    assertEq(input.balanceOf(address(adapter)), 0);
    assertEq(input.allowance(address(adapter), address(pool)), 0);
    assertEq(pool.lastCode(), code);
    assertEq(pool.lastSender(), address(adapter));
    assertEq(pool.lastDeadline(), deadline);
  }

  function test_ZeroRefCodeAndAdapterRecipient() public {
    a.mint(address(adapter), 100);
    (, uint256 out) = adapter.executeUSCore(
      abi.encode(address(pool), block.timestamp, bytes32(0)),
      100,
      address(a),
      address(b),
      address(adapter)
    );
    assertEq(b.balanceOf(address(adapter)), out);
    assertEq(pool.lastCode(), bytes32(0));
  }

  function test_ExpiredRollsBackApprovalAndFunds() public {
    vm.warp(100);
    a.mint(address(adapter), 100);
    vm.expectRevert(USCoreTestPool.Expired.selector);
    adapter.executeUSCore(
      abi.encode(address(pool), 99, bytes32(0)), 100, address(a), address(b), recipient
    );
    assertEq(a.balanceOf(address(adapter)), 100);
    assertEq(a.allowance(address(adapter), address(pool)), 0);
  }

  function test_RejectMalformedData() public {
    uint256[6] memory lengths = [uint256(0), 32, 64, 95, 97, 128];
    for (uint256 i; i < lengths.length; ++i) {
      bytes memory data = new bytes(lengths[i]);
      vm.expectRevert(USCoreAdapter.InvalidData.selector);
      adapter.executeUSCore(data, 100, address(a), address(b), recipient);
    }
  }

  function test_RejectNative() public {
    address[2] memory nativeTokens = [address(0), 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE];
    bytes memory data = abi.encode(address(pool), 100, bytes32(0));
    for (uint256 i; i < nativeTokens.length; ++i) {
      vm.expectRevert(USCoreAdapter.NativeTokenUnsupported.selector);
      adapter.executeUSCore(data, 100, nativeTokens[i], address(b), recipient);
      vm.expectRevert(USCoreAdapter.NativeTokenUnsupported.selector);
      adapter.executeUSCore(data, 100, address(a), nativeTokens[i], recipient);
    }
  }

  function test_TwoHopsThroughExecutor() public {
    USCoreTestExecutor executor = new USCoreTestExecutor();
    USCoreTestToken c = new USCoreTestToken('C');
    USCoreTestPool nextPool = new USCoreTestPool(b, c);
    c.mint(address(nextPool), 1_000_000e18);
    a.mint(address(executor), 10_000);
    uint256 deadline = block.timestamp + 300;
    bytes32 code = keccak256('uscore-test');
    bytes memory result = executor.run(
      address(adapter),
      abi.encodeCall(
        USCoreAdapter.executeUSCore,
        (
          abi.encode(address(pool), deadline, code),
          10_000,
          address(a),
          address(b),
          address(executor)
        )
      )
    );
    (uint256 unused, uint256 intermediate) = abi.decode(result, (uint256, uint256));
    assertEq(unused, 0);
    assertEq(intermediate, 9900);
    assertEq(b.balanceOf(address(executor)), intermediate);
    result = executor.run(
      address(adapter),
      abi.encodeCall(
        USCoreAdapter.executeUSCore,
        (
          abi.encode(address(nextPool), deadline, code),
          intermediate,
          address(b),
          address(c),
          recipient
        )
      )
    );
    uint256 out;
    (unused, out) = abi.decode(result, (uint256, uint256));
    assertEq(unused, 0);
    assertEq(out, 9801);
    assertEq(c.balanceOf(recipient), out);
    assertEq(a.balanceOf(address(executor)), 0);
    assertEq(b.balanceOf(address(executor)), 0);
    assertEq(c.balanceOf(address(executor)), 0);
    assertEq(a.allowance(address(executor), address(pool)), 0);
    assertEq(b.allowance(address(executor), address(nextPool)), 0);
    assertEq(pool.lastSender(), address(executor));
    assertEq(nextPool.lastSender(), address(executor));
    assertEq(pool.lastCode(), code);
    assertEq(nextPool.lastCode(), code);
  }

  function test_DelegatecallWithNativeValue() public {
    USCoreTestExecutor executor = new USCoreTestExecutor();
    a.mint(address(executor), 100);
    vm.deal(address(this), 1 ether);
    bytes memory result = executor.run{value: 1 ether}(
      address(adapter),
      abi.encodeCall(
        USCoreAdapter.executeUSCore,
        (
          abi.encode(address(pool), block.timestamp + 300, bytes32(0)),
          100,
          address(a),
          address(b),
          recipient
        )
      )
    );
    (uint256 unused, uint256 out) = abi.decode(result, (uint256, uint256));
    assertEq(unused, 0);
    assertEq(b.balanceOf(recipient), out);
    assertEq(a.balanceOf(address(executor)), 0);
    assertEq(pool.lastSender(), address(executor));
  }
}

contract USCoreTestExecutor {
  function run(address adapter, bytes calldata data) external payable returns (bytes memory) {
    (bool ok, bytes memory result) = adapter.delegatecall(data);
    require(ok, 'execution failed');
    return result;
  }
}
