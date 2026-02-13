// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

import 'src/adapters/wasabi-prop-amm/WasabiPropAmmAdapter.sol';

interface ITestPropPoolFactory {
  function getPropPool(address token) external view returns (address);
  function checkRole(uint64 roleId, address account) external view;
}

interface ITestPropPool {
  function getBaseToken() external view returns (address);
  function getQuoteToken() external view returns (address);
  function getPriceOracle() external view returns (address);
}

interface ITestPriceOracle {
  struct PriceData {
    uint256 price;
    uint8 precision;
    uint16 volatilityPips;
    uint256 lastUpdated;
  }

  function getUSDPrice(address token) external view returns (PriceData memory);
}

contract WasabiPropAmmAdapterTest is Test {
  using TokenHelper for address;
  WasabiPropAmmAdapter adapter;

  address constant FACTORY = 0x851fC799C9F1443A2c1e6B966605A80f8A1b1BF2;
  address constant BASE_WETH = 0x4200000000000000000000000000000000000006;
  address constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
  uint64 constant AUTHORIZED_SWAPPER_ROLE = 100;

  address pool;
  address recipient = makeAddr('recipient');

  string RPC_URL = 'https://mainnet.base.org';

  function setUp() public {
    vm.createSelectFork(RPC_URL);

    adapter = new WasabiPropAmmAdapter(BASE_WETH);
    pool = ITestPropPoolFactory(FACTORY).getPropPool(BASE_WETH);

    // Mock factory's checkRole to allow the adapter to swap
    vm.mockCall(
      FACTORY,
      abi.encodeWithSelector(
        ITestPropPoolFactory.checkRole.selector, AUTHORIZED_SWAPPER_ROLE, address(adapter)
      ),
      bytes('')
    );
  }

  function _warpToFreshOracle() internal {
    address oracle = ITestPropPool(pool).getPriceOracle();
    address baseToken = ITestPropPool(pool).getBaseToken();
    ITestPriceOracle.PriceData memory priceData = ITestPriceOracle(oracle).getUSDPrice(baseToken);
    vm.warp(priceData.lastUpdated + 1);
  }

  function test_executeWasabiPropAmm(uint256 amountIn, bool tokenToUSDC) public {
    vm.assume(pool != address(0));
    _warpToFreshOracle();

    address tokenIn;
    address tokenOut;
    if (tokenToUSDC) {
      tokenIn = BASE_WETH;
      tokenOut = BASE_USDC;
      amountIn = bound(amountIn, 1e15, 1e18);
    } else {
      tokenIn = BASE_USDC;
      tokenOut = BASE_WETH;
      amountIn = bound(amountIn, 1e6, 3000e6);
    }

    deal(tokenIn, address(adapter), amountIn);

    bytes memory data = abi.encode(pool);
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeWasabiPropAmm(data, amountIn, tokenIn, tokenOut, recipient);

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    // ERC20 output stays in adapter
    assertEq(amountOut, tokenOut.balanceOf(address(adapter)));
    // Input token fully consumed
    assertEq(tokenIn.balanceOf(address(adapter)), 0);
  }

  function test_executeWasabiPropAmm_nativeETHIn(uint256 amountIn) public {
    vm.assume(pool != address(0));
    _warpToFreshOracle();

    amountIn = bound(amountIn, 1e15, 1e18);
    deal(address(adapter), amountIn);

    bytes memory data = abi.encode(pool);
    (uint256 amountUnused, uint256 amountOut) = adapter.executeWasabiPropAmm(
      data, amountIn, TokenHelper.NATIVE_ADDRESS, BASE_USDC, recipient
    );

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    // USDC output stays in adapter
    assertEq(amountOut, BASE_USDC.balanceOf(address(adapter)));
    // No remaining ETH or WETH in adapter
    assertEq(address(adapter).balance, 0);
    assertEq(BASE_WETH.balanceOf(address(adapter)), 0);
  }

  function test_executeWasabiPropAmm_nativeETHOut(uint256 amountIn) public {
    vm.assume(pool != address(0));
    _warpToFreshOracle();

    amountIn = bound(amountIn, 1e6, 3000e6);
    deal(BASE_USDC, address(adapter), amountIn);

    uint256 recipientBalanceBefore = recipient.balance;

    bytes memory data = abi.encode(pool);
    (uint256 amountUnused, uint256 amountOut) = adapter.executeWasabiPropAmm(
      data, amountIn, BASE_USDC, TokenHelper.NATIVE_ADDRESS, recipient
    );

    assertEq(amountUnused, 0);
    assertGt(amountOut, 0);
    // Native ETH sent to recipient
    assertEq(amountOut, recipient.balance - recipientBalanceBefore);
    // No remaining tokens in adapter
    assertEq(BASE_USDC.balanceOf(address(adapter)), 0);
    assertEq(BASE_WETH.balanceOf(address(adapter)), 0);
    assertEq(address(adapter).balance, 0);
  }
}
