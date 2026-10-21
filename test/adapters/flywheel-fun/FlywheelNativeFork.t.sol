// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import 'forge-std/Test.sol';
import {IERC20} from 'openzeppelin-contracts/contracts/token/ERC20/IERC20.sol';
import {FlywheelNativeAdapter} from 'src/adapters/flywheel-fun/FlywheelNativeAdapter.sol';
import {IFlywheelWETH} from 'src/adapters/flywheel-fun/IFlywheelNative.sol';

interface IFlywheelTestGateway {
  struct Metadata {
    string logoURI;
    string description;
    string website;
    string twitter;
    string telegram;
  }

  struct Launch {
    address quote;
    string name;
    string symbol;
    Metadata metadata;
    uint256 supply;
    uint256 offset;
    uint256 threshold;
    bool holders;
  }

  struct Purchase {
    uint256 minQuote;
    uint256 minTokens;
    uint256 deadline;
    bytes route;
    uint256 minRefundETH;
    bytes refundRoute;
  }
  function launch(Launch calldata, Purchase calldata) external payable returns (address);
}

interface IFlywheelTestFactory {
  function launchFeeWei() external view returns (uint256);
  function buy(address token, uint256 amount, uint256 minimum) external payable returns (uint256);
  function sell(address token, uint256 amount, uint256 minimum) external returns (uint256);
  function compoundConfig(address token) external view returns (address, address, address, uint256);
}

struct FlywheelForkPoolKey {
  address currency0;
  address currency1;
  uint24 fee;
  int24 tickSpacing;
  address hooks;
}

interface IFlywheelForkPoolView {
  function poolKey() external view returns (FlywheelForkPoolKey memory);
}

interface IFlywheelForkPoolManager {
  struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
  }
  function unlock(bytes calldata data) external returns (bytes memory);
  function swap(FlywheelForkPoolKey calldata, SwapParams calldata, bytes calldata)
    external
    returns (int256);
}

/// @dev Deliberately attempts a normal V4 router's PoolManager path. No balances
/// are funded: the test checks the exact hook authorization error before payment.
contract FlywheelDirectPoolProbe {
  IFlywheelForkPoolManager constant MANAGER =
    IFlywheelForkPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);

  function attempt(FlywheelForkPoolKey calldata key, bool zeroForOne) external {
    MANAGER.unlock(abi.encode(key, zeroForOne));
  }

  function unlockCallback(bytes calldata data) external returns (bytes memory) {
    require(msg.sender == address(MANAGER), 'manager only');
    (FlywheelForkPoolKey memory key, bool zeroForOne) =
      abi.decode(data, (FlywheelForkPoolKey, bool));
    MANAGER.swap(
      key,
      IFlywheelForkPoolManager.SwapParams(
        zeroForOne,
        -int256(1e10),
        zeroForOne
          ? 4_295_128_740
          : 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341
      ),
      ''
    );
    revert('unexpected authorization');
  }
}

/// @dev Test-only atomic executor. Not Kyber's deployed executor or production code.
contract FlywheelForkExecutor {
  receive() external payable {}

  function execute(address module, bytes calldata data) external payable returns (bytes memory) {
    (bool ok, bytes memory result) = module.delegatecall(data);
    if (!ok) {
      assembly ('memory-safe') { revert(add(result, 32), mload(result)) }
    }
    return result;
  }

  function refund(address payable recipient, uint256 amount) external {
    (bool ok,) = recipient.call{value: amount}('');
    require(ok, 'refund failed');
  }
}

contract FlywheelNativeForkTest is Test {
  address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address constant BOOMER = 0x73c2dE14C7FA0a57cc2d9722b959eA70B881fFe4;
  address constant WETH_POOL = 0x3245AF253DC425459c331b2FF8b2fe170D781aE5;
  address constant BOOMER_POOL = 0x0d451b146208549B4C6bDc86d8aE7830f91eFD84;
  address BOOMER_CURVE;
  address constant GATEWAY = 0x341649D9A20fAf349aB8F1a1a4449bDa47cFAb35;

  struct Key {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
  }
  FlywheelNativeAdapter adapter;
  address recipient;

  function setUp() public {
    string memory rpc = vm.envOr('FLYWHEEL_READONLY_FORK_URL', string(''));
    if (bytes(rpc).length == 0) {
      vm.skip(true);
      return;
    }
    vm.createSelectFork(rpc, 82_183_340);
    require(block.chainid == 4663, 'wrong fork');
    adapter = new FlywheelNativeAdapter();
    recipient = makeAddr('kyber-user');
    vm.deal(address(this), 1 ether);
    BOOMER_CURVE = launchCustomCurve(BOOMER, 1e24);
  }

  function route(bool boomer) internal pure returns (bytes memory) {
    if (!boomer) return '';
    Key[] memory keys = new Key[](1);
    keys[0] = Key(address(0), BOOMER, 98_700, 987, address(0));
    return abi.encode(keys);
  }

  function trade(address token, bool boomer)
    internal
    view
    returns (FlywheelNativeAdapter.Trade memory t)
  {
    t.token = token;
    t.minQuote = 1;
    t.minOutput = 1;
    t.deadline = block.timestamp + 300;
    t.route = route(boomer);
  }

  function roundTrip(address token, bool boomer, bool wrapped) internal {
    address input = wrapped ? adapter.WETH() : ETH;
    uint256 amount = 10_000_000_000;
    if (wrapped) {
      IFlywheelWETH(input).deposit{value: amount}();
      IERC20(input).transfer(address(adapter), amount);
    }
    FlywheelNativeAdapter.Trade memory t = trade(token, boomer);
    (uint256 unused, uint256 output) = adapter.executeFlywheelNative{value: wrapped ? 0 : amount}(
      abi.encode(t), amount, input, token, recipient
    );
    assertEq(unused, 0);
    assertGt(output, 0);
    assertEq(IERC20(token).balanceOf(recipient), output);
    assertEq(IERC20(token).balanceOf(address(adapter)), 0);
    assertEq(address(adapter).balance, 0);
    uint256 sold = output / 2;
    vm.prank(recipient);
    IERC20(token).transfer(address(adapter), sold);
    (unused, output) = adapter.executeFlywheelNative(abi.encode(t), sold, token, input, recipient);
    assertEq(unused, 0);
    assertGt(output, 0);
    assertLt(output, amount);
    assertEq(IERC20(token).allowance(address(adapter), adapter.SETTLEMENT()), 0);
    assertEq(IERC20(token).balanceOf(address(adapter)), 0);
    assertEq(address(adapter).balance, 0);
    if (wrapped) assertEq(IERC20(input).balanceOf(recipient), output);
    else assertEq(recipient.balance, output);
  }

  function testFork_wethGraduatedRoundTrip() public {
    roundTrip(WETH_POOL, false, false);
  }

  function testFork_boomerGraduatedRoundTrip() public {
    roundTrip(BOOMER_POOL, true, false);
  }

  function testFork_boomerCurveRoundTrip() public {
    roundTrip(BOOMER_CURVE, true, false);
  }

  function testFork_wrappedBoomerRoundTrip() public {
    roundTrip(BOOMER_POOL, true, true);
  }

  function testFork_directCurveRejectedButAdapterWorks() public {
    IFlywheelTestFactory factory = IFlywheelTestFactory(adapter.FACTORY());
    vm.expectRevert(bytes('native adapter only'));
    factory.buy(BOOMER_CURVE, 1e10, 1);
    vm.expectRevert(bytes('native adapter only'));
    factory.sell(BOOMER_CURVE, 1e10, 1);
    roundTrip(BOOMER_CURVE, true, false);
  }

  function testFork_directV4SwapRejectedButAdapterWorks() public {
    (address quote, address poolView,, uint256 position) =
      IFlywheelTestFactory(adapter.FACTORY()).compoundConfig(WETH_POOL);
    assertGt(position, 0, 'fixture must be graduated');
    FlywheelForkPoolKey memory key = IFlywheelForkPoolView(poolView).poolKey();
    FlywheelDirectPoolProbe probe = new FlywheelDirectPoolProbe();
    bytes memory hookRevert = abi.encodeWithSignature('Error(string)', 'native settlement only');
    bytes4 beforeSwapSelector = bytes4(
      keccak256(
        'beforeSwap(address,(address,address,uint24,int24,address),(bool,int256,uint160),bytes)'
      )
    );
    vm.expectRevert(
      abi.encodeWithSignature(
        'WrappedError(address,bytes4,bytes,bytes)',
        key.hooks,
        beforeSwapSelector,
        hookRevert,
        abi.encodePacked(bytes4(keccak256('HookCallFailed()')))
      )
    );
    probe.attempt(key, quote == key.currency0);
    roundTrip(WETH_POOL, false, false);
  }

  function launchCurve(uint256 threshold) internal returns (address) {
    return launchCustomCurve(adapter.WETH(), threshold);
  }

  function launchCustomCurve(address pairing, uint256 threshold) internal returns (address) {
    IFlywheelTestGateway.Launch memory config;
    config.quote = pairing;
    config.name = 'KYBER LOCAL FORK ONLY';
    config.symbol = 'KYBERTEST';
    config.supply = 1e29;
    config.offset = threshold * 3 / 10;
    config.threshold = threshold;
    config.holders = true;
    IFlywheelTestGateway.Purchase memory purchase;
    purchase.deadline = block.timestamp + 300;
    return IFlywheelTestGateway(GATEWAY)
    .launch{value: IFlywheelTestFactory(adapter.FACTORY()).launchFeeWei()}(
      config, purchase
    );
  }

  function testFork_curveGraduationRefund() public {
    address token = launchCurve(1e11);
    FlywheelNativeAdapter.Trade memory t = trade(token, false);
    t.minRefundETH = 1;
    (uint256 unused, uint256 output) =
      adapter.executeFlywheelNative{value: 2e11}(abi.encode(t), 2e11, ETH, token, recipient);
    assertGt(unused, 0);
    assertLt(unused, 2e11);
    assertEq(address(adapter).balance, unused);
    assertEq(IERC20(token).balanceOf(recipient), output);
    assertGt(output, 0);
    // Sell after the same purchase graduated the token; protect the unused ETH.
    uint256 sold = output / 100;
    vm.prank(recipient);
    IERC20(token).transfer(address(adapter), sold);
    t.minRefundETH = 0;
    adapter.executeFlywheelNative(abi.encode(t), sold, token, ETH, recipient);
    assertEq(address(adapter).balance, unused);
    assertGt(recipient.balance, 0);
  }

  function testFork_delegatecallGraduationRefundAndSell() public {
    address token = launchCurve(1e11);
    FlywheelForkExecutor executor = new FlywheelForkExecutor();
    uint256 donated = 123;
    vm.deal(address(executor), donated);
    FlywheelNativeAdapter.Trade memory t = trade(token, false);
    t.minRefundETH = 1;
    bytes memory result = executor.execute{value: 2e11}(
      address(adapter),
      abi.encodeCall(
        adapter.executeFlywheelNative, (abi.encode(t), 2e11, ETH, token, address(executor))
      )
    );
    (uint256 unused, uint256 bought) = abi.decode(result, (uint256, uint256));
    assertGt(unused, 0);
    assertLt(unused, 2e11);
    assertGt(bought, 0);
    assertEq(IERC20(token).balanceOf(address(executor)), bought);
    assertEq(address(executor).balance, donated + unused);
    assertEq(address(adapter).balance, 0);

    t.minRefundETH = 0;
    result = executor.execute(
      address(adapter),
      abi.encodeCall(
        adapter.executeFlywheelNative, (abi.encode(t), bought / 100, token, ETH, recipient)
      )
    );
    (uint256 sellUnused, uint256 received) = abi.decode(result, (uint256, uint256));
    assertEq(sellUnused, 0);
    assertGt(received, 0);
    assertEq(recipient.balance, received);
    assertEq(address(executor).balance, donated + unused);
    assertEq(IERC20(token).allowance(address(executor), adapter.SETTLEMENT()), 0);
    executor.refund(payable(recipient), unused);
    assertEq(recipient.balance, received + unused);
    assertEq(address(executor).balance, donated);
  }

  function testFork_overfillWithoutRefundReverts() public {
    address token = launchCurve(1e11);
    vm.expectRevert();
    adapter.executeFlywheelNative{value: 2e11}(
      abi.encode(trade(token, false)), 2e11, ETH, token, recipient
    );
    assertEq(IERC20(token).balanceOf(recipient), 0);
    assertEq(address(adapter).balance, 0);
  }

  function testFork_invalidExternalRouteReverts() public {
    FlywheelNativeAdapter.Trade memory t = trade(BOOMER_CURVE, true);
    t.route = hex'010203';
    vm.expectRevert();
    adapter.executeFlywheelNative{value: 1e10}(abi.encode(t), 1e10, ETH, BOOMER_CURVE, recipient);
    assertEq(IERC20(BOOMER_CURVE).balanceOf(recipient), 0);
  }
}
