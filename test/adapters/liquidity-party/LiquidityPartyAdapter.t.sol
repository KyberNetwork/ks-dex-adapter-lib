// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/liquidity-party/LiquidityPartyAdapter.sol';

/// @notice PartyInfo view helper used to cross-check the executed swap output to the wei.
interface IPartyInfo {
  function swapAmounts(address pool, uint256 i, uint256 j, uint256 maxAmountIn)
    external
    view
    returns (uint256 amountIn, uint256 amountOut, uint256 outFee);
}

/// @dev Exposes the internal packed-calldata decoder for unit testing.
contract LiquidityPartyAdapterExposed is LiquidityPartyAdapter {
  function decodeData(bytes calldata data)
    external
    pure
    returns (address pool, uint256 indexIn, uint256 indexOut)
  {
    return _decodeData(data);
  }
}

contract LiquidityPartyAdapterTest is Test {
  using TokenHelper for address;

  LiquidityPartyAdapterExposed adapter;

  // Mainnet Liquidity Party deployment (chainId 1), see ../lmsr-amm/deployment/liqp-deployments.json.
  address constant PARTY_INFO = 0xefF3Ed388D3887e7C9F375B7f1ad8A0B77C05643;
  // Live 3-token test pool: [USDC(0), WETH(1), AAVE(2)].
  address constant POOL = 0x1270Da05Cf1d047763CEEfDe25a4a5438b26fdA6;

  address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // index 0, 6 decimals
  address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // index 1, 18 decimals
  address constant AAVE = 0x7Fc66500c84A76Ad7e9c93437bFc5Ac33E2DDaE9; // index 2, 18 decimals

  uint256 constant USDC_INDEX = 0;
  uint256 constant WETH_INDEX = 1;
  uint256 constant AAVE_INDEX = 2;

  address[3] tokens = [USDC, WETH, AAVE];

  address recipient = makeAddr('recipient');

  // Fixed fork for a known pool state (matches the dex-lib golden tests). Override RPC via RPC_1.
  string RPC_URL = vm.envOr('RPC_1', string('https://1rpc.io/eth'));
  uint256 constant BLOCK_NUMBER = 25_301_966;

  function setUp() public {
    vm.createSelectFork(RPC_URL, BLOCK_NUMBER);
    adapter = new LiquidityPartyAdapterExposed();
  }

  function testDecodeData() public view {
    address mockPool = 0x1234567890123456789012345678901234567890;
    bytes memory data = abi.encode(mockPool, uint256(3), uint256(7));

    (address pool, uint256 indexIn, uint256 indexOut) = adapter.decodeData(data);

    assertEq(pool, mockPool, 'pool');
    assertEq(indexIn, 3, 'indexIn');
    assertEq(indexOut, 7, 'indexOut');
    assertEq(data.length, 96, 'abi.encode(pool, i, j) is 3 words');
  }

  /// @dev Runs one swap through the adapter and asserts the executed output matches
  ///      PartyInfo.swapAmounts to the wei, plus the KyberSwap two-value return contract.
  function _runAndCheck(uint256 i, uint256 j, uint256 amountIn) internal {
    address tokenIn = tokens[i];
    address tokenOut = tokens[j];

    (, uint256 expectedOut,) = IPartyInfo(PARTY_INFO).swapAmounts(POOL, i, j, amountIn);
    assertGt(expectedOut, 0, 'expected output should be positive');

    // prefund the adapter (the executor does this in production), never the pool
    deal(tokenIn, address(adapter), amountIn);

    bytes memory data = abi.encode(POOL, i, j);

    uint256 balOutBefore = tokenOut.balanceOf(recipient);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeLiquidityParty(data, amountIn, tokenIn, tokenOut, recipient);

    assertEq(amountUnused, 0, 'no unused input');
    assertEq(amountOut, expectedOut, 'amountOut matches PartyInfo.swapAmounts to the wei');
    assertEq(
      tokenOut.balanceOf(recipient) - balOutBefore, amountOut, 'recipient received amountOut'
    );
    assertEq(tokenIn.balanceOf(address(adapter)), 0, 'input fully consumed');
  }

  function test_swap_USDC_to_WETH() public {
    _runAndCheck(USDC_INDEX, WETH_INDEX, 300_000); // 0.3 USDC
  }

  function test_swap_WETH_to_USDC() public {
    _runAndCheck(WETH_INDEX, USDC_INDEX, 200_000_000_000_000); // 0.0002 WETH
  }

  function test_swap_USDC_to_AAVE() public {
    _runAndCheck(USDC_INDEX, AAVE_INDEX, 300_000); // 0.3 USDC
  }

  function test_swap_AAVE_to_WETH() public {
    _runAndCheck(AAVE_INDEX, WETH_INDEX, 5_000_000_000_000_000); // 0.005 AAVE
  }

  function test_swap_AAVE_to_USDC() public {
    _runAndCheck(AAVE_INDEX, USDC_INDEX, 5_000_000_000_000_000); // 0.005 AAVE
  }
}
