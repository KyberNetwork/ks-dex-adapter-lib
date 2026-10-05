// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import 'openzeppelin-contracts/contracts/token/ERC20/ERC20.sol';

import 'src/adapters/mento-v3/IMentoFPMM.sol';
import 'src/adapters/mento-v3/MentoV3Adapter.sol';

contract MentoV3TestToken is ERC20 {
  constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

/// @dev Minimal FPMM look-alike: fixed rate `numerator/denominator`, fee in bps taken from the
///      output, Uniswap-V2-style swap that infers the input from its balance delta.
contract MentoV3MockPool is IMentoFPMM {
  address public immutable token0;
  address public immutable token1;
  uint256 public immutable rateNumerator; // token1 per token0, 1e18-scaled
  uint256 public immutable feeBps;

  uint256 public reserve0;
  uint256 public reserve1;

  uint256 public lastAmount0Out;
  uint256 public lastAmount1Out;
  address public lastTo;

  constructor(address token0_, address token1_, uint256 rateNumerator_, uint256 feeBps_) {
    require(token0_ < token1_, 'unsorted');
    token0 = token0_;
    token1 = token1_;
    rateNumerator = rateNumerator_;
    feeBps = feeBps_;
  }

  function sync() external {
    reserve0 = IERC20(token0).balanceOf(address(this));
    reserve1 = IERC20(token1).balanceOf(address(this));
  }

  function getReserves() external view returns (uint256, uint256, uint256) {
    return (reserve0, reserve1, block.timestamp);
  }

  function getAmountOut(uint256 amountIn, address tokenIn) public view returns (uint256) {
    if (tokenIn == token0) {
      return (amountIn * rateNumerator * (10_000 - feeBps)) / (1e18 * 10_000);
    }
    require(tokenIn == token1, 'InvalidToken');
    return (amountIn * 1e18 * (10_000 - feeBps)) / (rateNumerator * 10_000);
  }

  function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata) external {
    require(amount0Out < reserve0 && amount1Out < reserve1, 'InsufficientLiquidity');
    if (amount0Out > 0) IERC20(token0).transfer(to, amount0Out);
    if (amount1Out > 0) IERC20(token1).transfer(to, amount1Out);

    uint256 balance0 = IERC20(token0).balanceOf(address(this));
    uint256 balance1 = IERC20(token1).balanceOf(address(this));
    uint256 amount0In = balance0 > reserve0 - amount0Out ? balance0 - (reserve0 - amount0Out) : 0;
    uint256 amount1In = balance1 > reserve1 - amount1Out ? balance1 - (reserve1 - amount1Out) : 0;
    require(amount0In > 0 || amount1In > 0, 'InsufficientInputAmount');
    // value check: the caller must not take more than the oracle-priced output
    if (amount0In > 0) {
      require(amount1Out <= getAmountOut(amount0In, token0), 'ReserveValueDecreased');
    }
    if (amount1In > 0) {
      require(amount0Out <= getAmountOut(amount1In, token1), 'ReserveValueDecreased');
    }

    reserve0 = balance0;
    reserve1 = balance1;
    lastAmount0Out = amount0Out;
    lastAmount1Out = amount1Out;
    lastTo = to;
  }
}

contract MentoV3AdapterTest is Test {
  MentoV3Adapter adapter;
  MentoV3MockPool pool;
  MentoV3TestToken token0;
  MentoV3TestToken token1;

  address recipient = makeAddr('recipient');

  // The executor often holds dust or output from earlier hops, so the adapter never starts empty.
  uint256 constant DUST0 = 0.123 ether;
  uint256 constant DUST1 = 4.567 ether;

  function setUp() public {
    adapter = new MentoV3Adapter();

    MentoV3TestToken a = new MentoV3TestToken('A', 'A');
    MentoV3TestToken b = new MentoV3TestToken('B', 'B');
    (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

    // 1 token0 = 0.99993551 token1, 5 bps total fee (Monad USDC/USDm parameters)
    pool = new MentoV3MockPool(address(token0), address(token1), 0.999_935_51 ether, 5);
    token0.mint(address(pool), 1_000_000 ether);
    token1.mint(address(pool), 1_000_000 ether);
    pool.sync();

    token0.mint(address(adapter), DUST0);
    token1.mint(address(adapter), DUST1);
  }

  function test_executeMentoV3_zeroForOne() public {
    uint256 amountIn = 10 ether;
    token0.mint(address(adapter), amountIn);

    uint256 expected = pool.getAmountOut(amountIn, address(token0));
    bytes memory data = abi.encode(address(pool));
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeMentoV3(data, amountIn, address(token0), address(token1), recipient);

    assertEq(amountUnused, 0);
    assertEq(amountOut, expected);
    assertEq(amountOut, 9.994_355_422_45 ether);
    assertEq(token1.balanceOf(recipient), amountOut);
    // only amountIn left the adapter; pre-existing balances of both tokens are untouched
    assertEq(token0.balanceOf(address(adapter)), DUST0);
    assertEq(token1.balanceOf(address(adapter)), DUST1);
    assertEq(pool.lastAmount0Out(), 0);
    assertEq(pool.lastAmount1Out(), amountOut);
    assertEq(pool.lastTo(), recipient);
  }

  function test_executeMentoV3_oneForZero() public {
    uint256 amountIn = 10 ether;
    token1.mint(address(adapter), amountIn);

    uint256 expected = pool.getAmountOut(amountIn, address(token1));
    bytes memory data = abi.encode(address(pool));
    (uint256 amountUnused, uint256 amountOut) =
      adapter.executeMentoV3(data, amountIn, address(token1), address(token0), recipient);

    assertEq(amountUnused, 0);
    assertEq(amountOut, expected);
    assertEq(token0.balanceOf(recipient), amountOut);
    assertEq(token0.balanceOf(address(adapter)), DUST0);
    assertEq(token1.balanceOf(address(adapter)), DUST1);
    assertEq(pool.lastAmount0Out(), amountOut);
    assertEq(pool.lastAmount1Out(), 0);
    assertEq(pool.lastTo(), recipient);
  }

  function testFuzz_executeMentoV3(uint256 amountIn, bool zeroForOne) public {
    amountIn = bound(amountIn, 1, 100_000 ether);
    (MentoV3TestToken tokenIn, MentoV3TestToken tokenOut) =
      zeroForOne ? (token0, token1) : (token1, token0);
    uint256 adapterInBefore = tokenIn.balanceOf(address(adapter));
    uint256 adapterOutBefore = tokenOut.balanceOf(address(adapter));
    tokenIn.mint(address(adapter), amountIn);

    (uint256 amountUnused, uint256 amountOut) = adapter.executeMentoV3(
      abi.encode(address(pool)), amountIn, address(tokenIn), address(tokenOut), recipient
    );

    assertEq(amountUnused, 0);
    assertEq(amountOut, pool.getAmountOut(amountIn, address(tokenIn)));
    assertEq(tokenOut.balanceOf(recipient), amountOut);
    assertEq(tokenIn.balanceOf(address(adapter)), adapterInBefore);
    assertEq(tokenOut.balanceOf(address(adapter)), adapterOutBefore);
  }
}
