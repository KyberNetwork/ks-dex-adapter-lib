// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Vm} from 'forge-std/Vm.sol';

library HyperEVMFork {
  Vm constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  function enableReadPrecompiles() internal {
    for (uint160 target = 0x0800; target < 0x0820; ++target) {
      vm.etch(address(target), type(HyperEVMReadRelay).runtimeCode);
      vm.allowCheatcodes(address(target));
    }
  }
}

contract HyperEVMReadRelay {
  Vm constant vm = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  fallback(bytes calldata input) external returns (bytes memory output) {
    output = vm.rpc(
      'eth_call',
      string.concat(
        '[{"to":"', vm.toString(address(this)), '","data":"', vm.toString(input), '"},"latest"]'
      )
    );
    vm.mockCall(address(this), input, output);
  }
}
