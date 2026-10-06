// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import './IMentoFPMM.sol';

import '../../libraries/CalldataDecoder.sol';
import '../../libraries/TokenHelper.sol';

/// @title MentoV3Adapter
/// @notice KyberSwap DEX adapter for Mento V3 fixed-price market maker (FPMM) pools.
///         Interacts with the pool directly: quote via the pool's oracle-priced `getAmountOut`,
///         transfer the input, then call the Uniswap-V2-style `swap`.
/// @dev FPMM pools price against an oracle rate, so `getAmountOut` is exact and the pool's
///      value-invariant check accepts it. Tokens are sorted (token0 < token1) by the factory.
///      FPMM swaps consume the whole input, so `amountUnused` is always zero. Mento pool tokens
///      are plain ERC20s (no fee-on-transfer, no rebasing), so the quoted amount is the amount
///      the recipient receives.
contract MentoV3Adapter {
  using CalldataDecoder for bytes;
  using TokenHelper for address;

  /// @notice Execute a single-hop swap on a Mento V3 FPMM pool.
  /// @param data ABI-encoded: (address pool)
  /// @param amountIn Amount of tokenIn to swap, already held by this adapter
  /// @param tokenIn Input token address
  /// @param tokenOut Output token address
  /// @param recipient Recipient of the output tokens
  /// @return amountUnused Always zero
  /// @return amountOut Amount of tokenOut sent to the recipient
  function executeMentoV3(
    bytes calldata data,
    uint256 amountIn,
    address tokenIn,
    address tokenOut,
    address recipient
  ) external payable returns (uint256 amountUnused, uint256 amountOut) {
    address pool = _decodeData(data);

    amountOut = IMentoFPMM(pool).getAmountOut(amountIn, tokenIn);

    tokenIn.safeTransfer(pool, amountIn);

    if (tokenIn < tokenOut) {
      IMentoFPMM(pool).swap(0, amountOut, recipient, '');
    } else {
      IMentoFPMM(pool).swap(amountOut, 0, recipient, '');
    }
  }

  function _decodeData(bytes calldata data) internal pure returns (address pool) {
    pool = data.decodeAddress(0);
  }
}
