// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import 'forge-std/Vm.sol';

/// @dev Arc's USDC keeps balances as the native coin and moves them through a precompile at
///      0x1800...00 - transfer(from, to, amount), amounts in the native 18 decimals - that Foundry does
///      not run. This stands in for that one call so a fork can move USDC; balances are read natively.
///      What it moves with vm.deal is not undone when the calling frame reverts.
contract ArcNativeCoinAuthorityMock {
  address internal constant ADDRESS = 0x1800000000000000000000000000000000000000;

  Vm constant VM = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  fallback(bytes calldata data) external returns (bytes memory) {
    require(bytes4(data[:4]) == bytes4(0xbeabacc8), 'unsupported native coin call');
    (address from, address to, uint256 amount) = abi.decode(data[4:], (address, address, uint256));
    VM.deal(from, from.balance - amount);
    VM.deal(to, to.balance + amount);
    return abi.encode(true);
  }
}

/// @dev Arc's USDC asks a second system contract, at 0x1800...01, whether an address is blocklisted
///      before it moves anything with transferFrom. Foundry does not run that one either, so this
///      answers what it answers for every address these tests use: no.
contract ArcBlocklistAuthorityMock {
  fallback(bytes calldata) external returns (bytes memory) {
    return abi.encode(false);
  }
}
