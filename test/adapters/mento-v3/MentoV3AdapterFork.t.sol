// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/interfaces/IERC20.sol';

import 'src/adapters/mento-v3/MentoV3Adapter.sol';

/// @notice Fork integration test against the deployed Mento V3 USDC/USDm FPMM on Monad.
/// @dev Requires RPC_143 (the `monad_mainnet` alias in foundry.toml). Mento's oracle must be
///      fresh at the forked block for the swap to execute.
contract MentoV3AdapterForkTest is Test {
  MentoV3Adapter adapter;

  address constant POOL = 0x463c0d1F04bcd99A1efCF94AC2a75bc19Ea4A7E5;
  address constant USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
  address constant USDm = 0xBC69212B8E4d445b2307C9D32dD68E2A4Df00115;

  address recipient = makeAddr('recipient');

  function setUp() public {
    vm.createSelectFork('monad_mainnet');
    adapter = new MentoV3Adapter();
  }

  function test_executeMentoV3_usdcToUsdm() public {
    uint256 amountIn = 1_000_000; // 1 USDC (6 decimals)
    deal(USDC, address(adapter), amountIn);

    uint256 expected = IMentoFPMM(POOL).getAmountOut(amountIn, USDC);
    uint256 balanceBefore = IERC20(USDm).balanceOf(recipient);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeMentoV3(abi.encode(POOL), amountIn, USDC, USDm, recipient);

    assertEq(amountUnused, 0);
    assertEq(amountOut, expected);
    assertGt(amountOut, 0);
    assertEq(IERC20(USDm).balanceOf(recipient) - balanceBefore, amountOut);
    assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
  }

  function test_executeMentoV3_usdmToUsdc() public {
    uint256 amountIn = 1 ether; // 1 USDm (18 decimals)
    deal(USDm, address(adapter), amountIn);

    uint256 expected = IMentoFPMM(POOL).getAmountOut(amountIn, USDm);
    uint256 balanceBefore = IERC20(USDC).balanceOf(recipient);

    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeMentoV3(abi.encode(POOL), amountIn, USDm, USDC, recipient);

    assertEq(amountUnused, 0);
    assertEq(amountOut, expected);
    assertGt(amountOut, 0);
    assertEq(IERC20(USDC).balanceOf(recipient) - balanceBefore, amountOut);
    assertEq(IERC20(USDm).balanceOf(address(adapter)), 0);
  }
}
