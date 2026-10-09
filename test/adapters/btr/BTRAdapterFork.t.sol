// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/interfaces/IERC20.sol';

import 'src/adapters/btr/BTRAdapter.sol';

interface IBTRAccess {
  function AC() external view returns (address);
}

interface IAccessControl {
  function owner() external view returns (address);
  function perms(address who) external view returns (uint256);
  function setPerms(address who, uint256 mask, bool on) external;
}

/// @notice Fork test against the BTR AIMM core on Monad.
/// @dev Requires RPC_143 (`monad_mainnet`). The live core is `SWAP_GATED`: only callers holding
///      lane 0x400 may swap. The executor delegatecalls the adapter, so the pool sees the executor
///      as `msg.sender`; `_grantLane` grants it on the fork only, standing in for BTR's on-chain
///      grant to the KyberSwap executor.
contract BTRAdapterForkTest is Test {
  using TokenHelper for address;

  address constant POOL = 0xbbbbbbb04f5b762A4CdD1d89E341e2537e3267e4;
  address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
  address constant WMON = 0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A;
  uint256 constant SWAP_LANE = 0x400;
  uint16 constant SWAP_GATED = 0x400;

  // The executor often holds dust or output from earlier hops, so it never starts empty.
  uint256 constant DUST_USDC = 123_456;
  uint256 constant DUST_WMON = 0.789 ether;

  BTRAdapter adapter;
  BTRTestExecutor executor;
  address recipient = makeAddr('recipient');

  function setUp() public {
    try vm.createSelectFork('monad_mainnet') {}
    catch {
      vm.skip(true, 'Monad fork needs the Monad EVM: run with FOUNDRY_NETWORK=monad');
    }
    adapter = new BTRAdapter();
    executor = new BTRTestExecutor();
    deal(USDC, address(executor), DUST_USDC);
    deal(WMON, address(executor), DUST_WMON);
  }

  function test_WMONToUSDC() public {
    _grantLane();
    _fundAndSwap(WMON, USDC, 1 ether, recipient);
  }

  function test_USDCToWMON() public {
    _grantLane();
    _fundAndSwap(USDC, WMON, 1e6, recipient);
  }

  function test_ExecutorRecipientRoundTrip() public {
    _grantLane();
    uint256 usdc = _fundAndSwap(WMON, USDC, 1 ether, address(executor));
    _assertSwap(USDC, WMON, usdc, recipient, block.timestamp + 300);
  }

  function testFuzz_WMONToUSDC(uint256 amountIn) public {
    _grantLane();
    _fundAndSwap(WMON, USDC, bound(amountIn, 0.1 ether, 10 ether), recipient);
  }

  function test_GatedWithoutLaneReverts() public {
    if ((IBTRPool(POOL).getRiskFlags(WMON) & SWAP_GATED) == 0) vm.skip(true, 'core not gated');
    deal(WMON, address(executor), DUST_WMON + 1 ether);
    vm.expectRevert(bytes4(keccak256('NotAuthorized()')));
    _run(WMON, USDC, 1 ether, recipient, block.timestamp + 300);
  }

  function test_ExpiredReverts() public {
    _grantLane();
    deal(WMON, address(executor), DUST_WMON + 1 ether);
    vm.expectRevert(bytes4(keccak256('Expired()')));
    _run(WMON, USDC, 1 ether, recipient, block.timestamp - 1);
    assertEq(WMON.balanceOf(address(executor)), DUST_WMON + 1 ether);
    assertEq(USDC.balanceOf(address(executor)), DUST_USDC);
  }

  function _grantLane() internal {
    IAccessControl ac = IAccessControl(IBTRAccess(POOL).AC());
    vm.prank(ac.owner());
    ac.setPerms(address(executor), SWAP_LANE, true);
    assertEq(ac.perms(address(executor)) & SWAP_LANE, SWAP_LANE);
  }

  function _fundAndSwap(address tokenIn, address tokenOut, uint256 amountIn, address to)
    internal
    returns (uint256)
  {
    deal(tokenIn, address(executor), tokenIn.balanceOf(address(executor)) + amountIn);
    return _assertSwap(tokenIn, tokenOut, amountIn, to, block.timestamp + 300);
  }

  function _assertSwap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    address to,
    uint256 deadline
  ) internal returns (uint256 amountOut) {
    uint256 expected = IBTRPool(POOL).getSwapQuote(tokenIn, tokenOut, amountIn).amountOut;
    assertGt(expected, 0);
    uint256 inBefore = tokenIn.balanceOf(address(executor));
    uint256 outBefore = tokenOut.balanceOf(to);
    uint256 executorOutBefore = tokenOut.balanceOf(address(executor));

    vm.expectCall(
      POOL, abi.encodeCall(IBTRPool.swap_qe, (tokenIn, tokenOut, amountIn, 1, to, deadline)), 1
    );
    uint256 amountUnused;
    (amountUnused, amountOut) =
      abi.decode(_run(tokenIn, tokenOut, amountIn, to, deadline), (uint256, uint256));

    assertEq(amountUnused, 0);
    // Same block, same state: the quote view matches a single fill exactly.
    assertEq(amountOut, expected);
    assertEq(inBefore - tokenIn.balanceOf(address(executor)), amountIn);
    assertEq(tokenOut.balanceOf(to) - outBefore, amountOut);
    if (to != address(executor)) {
      assertEq(tokenOut.balanceOf(address(executor)), executorOutBefore);
    }
    assertEq(IERC20(tokenIn).allowance(address(executor), POOL), 0);
  }

  function _run(address tokenIn, address tokenOut, uint256 amountIn, address to, uint256 deadline)
    internal
    returns (bytes memory)
  {
    return executor.run(
      address(adapter),
      abi.encodeCall(
        BTRAdapter.executeBTR, (abi.encode(POOL, deadline), amountIn, tokenIn, tokenOut, to)
      )
    );
  }
}

contract BTRTestExecutor {
  function run(address adapter, bytes calldata data) external returns (bytes memory) {
    (bool ok, bytes memory result) = adapter.delegatecall(data);
    if (!ok) {
      assembly ('memory-safe') {
        revert(add(result, 32), mload(result))
      }
    }
    return result;
  }
}
