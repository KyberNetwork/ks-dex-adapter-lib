## KyberSwap DEX Adapter Lib

This library is for ecosystem partners that want to implement their own DEX adapter for use in the KyberSwap DEX Aggregator.

### Contributing

Implement your own DEX adapter based on [UniswapV2Adapter](src/adapters/uniswap-v2/UniswapV2Adapter.sol) and [UniswapV3Adapter](src/adapters/uniswap-v3/UniswapV3Adapter.sol) and submit a PR to add it to the repository. Also, make sure to add tests for your adapter like the ones in [UniswapV2Adapter.t.sol](test/adapters/uniswap-v2/UniswapV2Adapter.t.sol) and [UniswapV3Adapter.t.sol](test/adapters/uniswap-v3/UniswapV3Adapter.t.sol).

Below are few assumptions you must follow before implementing your own adapter:

- There are no limitations on the contracts that the adapter can interact with.
- The input tokens are already transferred to the adapter contract.
- Prefer to interact directly with pool contracts if possible, rather than through router contracts.
- If your integration requires a callback function, implement it in the adapter contract.
- Use our libraries [TokenHelper](src/libraries/TokenHelper.sol) to interact with tokens and [CalldataDecoder](src/libraries/CalldataDecoder.sol) to decode calldata whenever possible.
- If your integration does not transfer the output tokens directly to the recipient, just leave them inside the adapter contract, don't need to explicitly transfer them.
- The adapter supports native tokens as input and output tokens, through symbolic address `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` (`TokenHelper.NATIVE_ADDRESS`).
- If your integration do not supports native tokens directly, you can simply ignore it.

Also don't forget to [ALLOW EDITS FROM MAINTAINERS IN THE PR SETTINGS](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/working-with-forks/allowing-changes-to-a-pull-request-branch-created-from-a-fork).