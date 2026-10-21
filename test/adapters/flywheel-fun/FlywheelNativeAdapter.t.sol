// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';
import 'src/adapters/flywheel-fun/FlywheelNativeAdapter.sol';

contract FlywheelTestToken is ERC20 {
  address public immutable factory;

  constructor(address factory_) ERC20('Test only', 'TEST') {
    factory = factory_;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

contract FlywheelTestWETH is ERC20 {
  constructor() ERC20('Wrapped test ETH', 'WETH') {}

  function deposit() external payable {
    _mint(msg.sender, msg.value);
  }

  function withdraw(uint256 amount) external {
    _burn(msg.sender, amount);
    (bool ok,) = msg.sender.call{value: amount}('');
    require(ok);
  }
}

contract FlywheelTestSettlement {
  bool public lie;

  function setLie(bool v) external {
    lie = v;
  }

  function buy(address token, uint256, uint256 minimum, uint256 deadline, bytes calldata)
    external
    payable
    returns (uint256 out)
  {
    require(deadline >= block.timestamp);
    out = msg.value * 2;
    require(out >= minimum);
    FlywheelTestToken(token).mint(msg.sender, out);
    if (lie) out++;
  }

  function buyWithRefund(
    address token,
    uint256,
    uint256 minimum,
    uint256 deadline,
    bytes calldata,
    uint256 minRefund,
    bytes calldata
  ) external payable returns (uint256 out) {
    require(deadline >= block.timestamp);
    uint256 refund = msg.value / 4;
    require(refund >= minRefund);
    out = (msg.value - refund) * 2;
    require(out >= minimum);
    FlywheelTestToken(token).mint(msg.sender, out);
    (bool ok,) = msg.sender.call{value: refund}('');
    require(ok);
  }

  function sell(
    address token,
    uint256 amount,
    uint256,
    uint256 minimum,
    uint256 deadline,
    bytes calldata
  ) external returns (uint256 out) {
    require(deadline >= block.timestamp);
    out = amount / 2;
    require(out >= minimum);
    ERC20(token).transferFrom(msg.sender, address(this), amount);
    (bool ok,) = msg.sender.call{value: out}('');
    require(ok);
    if (lie) out++;
  }
}

contract FlywheelRejectETH {}

contract FlywheelForwardETH {
  address payable public immutable destination;

  constructor(address payable to) {
    destination = to;
  }

  receive() external payable {
    (bool ok,) = destination.call{value: msg.value}('');
    require(ok);
  }
}

contract FlywheelReentryProbe {
  FlywheelNativeAdapter public adapter;
  bytes public payload;
  bool public nestedSucceeded;
  bytes4 public reason;

  constructor(FlywheelNativeAdapter a, bytes memory p) {
    adapter = a;
    payload = p;
  }

  receive() external payable {
    bytes memory errorData;
    (nestedSucceeded, errorData) = address(adapter).call(payload);
    if (errorData.length >= 4) reason = bytes4(errorData);
  }
}

contract FlywheelDelegateExecutor {
  receive() external payable {}

  function execute(address module, bytes calldata data) external payable returns (bytes memory) {
    (bool ok, bytes memory result) = module.delegatecall(data);
    if (!ok) {
      assembly ('memory-safe') { revert(add(result, 32), mload(result)) }
    }
    return result;
  }
}

contract FlywheelNativeAdapterTest is Test {
  FlywheelNativeAdapter adapter;
  FlywheelTestToken token;
  FlywheelTestSettlement settlement;
  address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
  address recipient;

  function setUp() public {
    vm.chainId(4663);
    vm.warp(1000);
    adapter = new FlywheelNativeAdapter();
    vm.etch(adapter.WETH(), address(new FlywheelTestWETH()).code);
    vm.etch(adapter.SETTLEMENT(), address(new FlywheelTestSettlement()).code);
    settlement = FlywheelTestSettlement(adapter.SETTLEMENT());
    vm.deal(address(settlement), 100 ether);
    token = new FlywheelTestToken(adapter.FACTORY());
    recipient = makeAddr('recipient');
    vm.deal(address(this), 100 ether);
  }

  function trade() internal view returns (FlywheelNativeAdapter.Trade memory t) {
    t.token = address(token);
    t.minQuote = 1;
    t.minOutput = 1;
    t.deadline = block.timestamp + 60;
  }

  function testFuzz_nativeBuyKeepsDonations(uint96 raw, uint96 donation) public {
    uint256 amount = bound(raw, 4, 10 ether);
    token.mint(address(adapter), donation);
    vm.deal(address(adapter), 123 + amount);
    (uint256 unused, uint256 output) =
      adapter.executeFlywheelNative(abi.encode(trade()), amount, ETH, address(token), recipient);
    assertEq(unused, 0);
    assertEq(output, amount * 2);
    assertEq(token.balanceOf(recipient), output);
    assertEq(token.balanceOf(address(adapter)), donation);
    assertEq(address(adapter).balance, 123);
  }

  function testFuzz_refundNativeOrWrapped(uint96 raw, bool wrapped) public {
    uint256 amount = bound(raw, 4, 10 ether);
    vm.deal(address(adapter), 123);
    address input = wrapped ? adapter.WETH() : ETH;
    if (wrapped) {
      FlywheelTestWETH(input).deposit{value: amount + 777}();
      ERC20(input).transfer(address(adapter), amount + 777);
    } else {
      vm.deal(address(adapter), 123 + amount);
    }
    FlywheelNativeAdapter.Trade memory t = trade();
    t.minRefundETH = 1;
    (uint256 unused, uint256 output) =
      adapter.executeFlywheelNative(abi.encode(t), amount, input, address(token), recipient);
    assertEq(unused, amount / 4);
    assertEq(output, (amount - unused) * 2);
    assertEq(token.balanceOf(recipient), output);
    if (wrapped) {
      assertEq(ERC20(input).balanceOf(address(adapter)), 777 + unused);
      assertEq(address(adapter).balance, 123);
    } else {
      assertEq(address(adapter).balance, 123 + unused);
    }
  }

  function testFuzz_sellNativeOrWrapped(uint96 raw, bool wrapped) public {
    uint256 amount = bound(raw, 2, 10 ether);
    token.mint(address(adapter), amount + 777);
    vm.deal(address(adapter), 123);
    address outputToken = wrapped ? adapter.WETH() : ETH;
    (uint256 unused, uint256 output) = adapter.executeFlywheelNative(
      abi.encode(trade()), amount, address(token), outputToken, recipient
    );
    assertEq(unused, 0);
    assertEq(output, amount / 2);
    assertEq(token.balanceOf(address(adapter)), 777);
    assertEq(address(adapter).balance, 123);
    assertEq(token.allowance(address(adapter), address(settlement)), 0);
    if (wrapped) assertEq(ERC20(outputToken).balanceOf(recipient), output);
    else assertEq(recipient.balance, output);
  }

  function test_delegatecallBuyAndSell() public {
    FlywheelDelegateExecutor executor = new FlywheelDelegateExecutor();
    bytes memory result = executor.execute{value: 1 ether}(
      address(adapter),
      abi.encodeCall(
        adapter.executeFlywheelNative,
        (abi.encode(trade()), 1 ether, ETH, address(token), address(executor))
      )
    );
    (, uint256 output) = abi.decode(result, (uint256, uint256));
    assertEq(output, 2 ether);
    executor.execute(
      address(adapter),
      abi.encodeCall(
        adapter.executeFlywheelNative, (abi.encode(trade()), output, address(token), ETH, recipient)
      )
    );
    assertEq(recipient.balance, 1 ether);
    assertEq(token.balanceOf(address(executor)), 0);
    assertEq(token.allowance(address(executor), address(settlement)), 0);
  }

  function test_wrongFactoryRejected() public {
    FlywheelTestToken wrong = new FlywheelTestToken(address(1));
    FlywheelNativeAdapter.Trade memory t = trade();
    t.token = address(wrong);
    vm.expectRevert(FlywheelNativeAdapter.InvalidTrade.selector);
    adapter.executeFlywheelNative{value: 1}(abi.encode(t), 1, ETH, address(wrong), recipient);
  }

  function test_wrongChainRejected() public {
    vm.chainId(1);
    vm.expectRevert(FlywheelNativeAdapter.InvalidTrade.selector);
    adapter.executeFlywheelNative{value: 1}(abi.encode(trade()), 1, ETH, address(token), recipient);
  }

  function test_expiredRejected() public {
    FlywheelNativeAdapter.Trade memory t = trade();
    t.deadline = block.timestamp - 1;
    vm.expectRevert(FlywheelNativeAdapter.InvalidTrade.selector);
    adapter.executeFlywheelNative{value: 1}(abi.encode(t), 1, ETH, address(token), recipient);
  }

  function test_zeroMinimumRejected() public {
    FlywheelNativeAdapter.Trade memory t = trade();
    t.minOutput = 0;
    vm.expectRevert(FlywheelNativeAdapter.InvalidTrade.selector);
    adapter.executeFlywheelNative{value: 1}(abi.encode(t), 1, ETH, address(token), recipient);
  }

  function test_wrongPairRejected() public {
    address weth = adapter.WETH();
    vm.expectRevert(FlywheelNativeAdapter.InvalidTrade.selector);
    adapter.executeFlywheelNative{value: 1}(abi.encode(trade()), 1, ETH, weth, recipient);
  }

  function test_sellRefundRouteRejected() public {
    token.mint(address(adapter), 4);
    FlywheelNativeAdapter.Trade memory t = trade();
    t.minRefundETH = 1;
    vm.expectRevert(FlywheelNativeAdapter.InvalidTrade.selector);
    adapter.executeFlywheelNative(abi.encode(t), 4, address(token), ETH, recipient);
  }

  function test_rejectedETHDeliveryRollsBack() public {
    token.mint(address(adapter), 4);
    address reject = address(new FlywheelRejectETH());
    vm.expectRevert();
    adapter.executeFlywheelNative(abi.encode(trade()), 4, address(token), ETH, reject);
    assertEq(token.balanceOf(address(adapter)), 4);
    assertEq(token.balanceOf(address(settlement)), 0);
  }

  function test_settlementOutputLieRejected() public {
    settlement.setLie(true);
    vm.expectRevert(FlywheelNativeAdapter.BalanceMismatch.selector);
    adapter.executeFlywheelNative{value: 4}(abi.encode(trade()), 4, ETH, address(token), recipient);
    assertEq(token.balanceOf(recipient), 0);
  }

  function test_impossibleMinimumRollsBack() public {
    FlywheelNativeAdapter.Trade memory t = trade();
    t.minOutput = 100;
    vm.expectRevert();
    adapter.executeFlywheelNative{value: 4}(abi.encode(t), 4, ETH, address(token), recipient);
    assertEq(token.balanceOf(recipient), 0);
  }

  function test_directETHCallbackRejected() public {
    (bool ok,) = address(adapter).call{value: 1}('');
    assertFalse(ok);
  }

  function test_forwardingETHRecipient() public {
    token.mint(address(adapter), 4);
    address forward = address(new FlywheelForwardETH(payable(recipient)));
    adapter.executeFlywheelNative(abi.encode(trade()), 4, address(token), ETH, forward);
    assertEq(recipient.balance, 2);
    assertEq(forward.balance, 0);
  }

  function test_recipientCannotReenterAndSpendResidualTokens() public {
    token.mint(address(adapter), 8);
    bytes memory p = abi.encodeCall(
      adapter.executeFlywheelNative, (abi.encode(trade()), 4, address(token), ETH, recipient)
    );
    FlywheelReentryProbe probe = new FlywheelReentryProbe(adapter, p);
    adapter.executeFlywheelNative(abi.encode(trade()), 4, address(token), ETH, address(probe));
    assertFalse(probe.nestedSucceeded());
    assertEq(probe.reason(), FlywheelNativeAdapter.ReentrantCall.selector);
    assertEq(token.balanceOf(address(adapter)), 4);
    assertEq(recipient.balance, 0);
    assertEq(address(probe).balance, 2);
  }

  function test_erc20InputRejectsUnexpectedETH() public {
    token.mint(address(adapter), 4);
    vm.expectRevert(FlywheelNativeAdapter.InvalidTrade.selector);
    adapter.executeFlywheelNative{value: 1}(abi.encode(trade()), 4, address(token), ETH, recipient);
    assertEq(token.balanceOf(address(adapter)), 4);
  }
}
