# Flywheel native settlement adapter — draft

Robinhood mainnet (4663), October 7 native factory `0xe7743b4039dbcd05c5242939aa8db274c65fcbfa` and settlement `0xad06b86264411e0278dbcebce556c913b44da004` only. This module calls the existing settlement before and after graduation. It does not bypass fees, swap directly through the restricted canonical pool, or change deployed Flywheel contracts.

`executeFlywheelNative(data, amountIn, tokenIn, tokenOut, recipient)` follows the prefunded adapter convention. `data` is `abi.encode(Trade)`, with fields in this order:

1. `address token`: launched token, authenticated by `factory()`.
2. `uint256 minQuote`: minimum pairing asset bought, or gross pairing asset received on selling.
3. `uint256 minOutput`: minimum final launch tokens or net ETH/WETH.
4. `uint256 deadline`: Unix seconds.
5. `bytes route`: authenticated NAT1 V3/V4 path, or the FWL1 envelope for up to two graduated native parents. It is forwarded unchanged to settlement.
6. `uint256 minRefundETH`: positive to opt into graduation overfill refunds; zero otherwise.
7. `bytes refundRoute`: separately protected reverse pairing-asset route; empty for WETH pairs.

Payment/output can be native ETH (Kyber's native address or zero) or Robinhood WETH. The other side must be a token from the pinned factory. WETH is unwrapped/wrapped inside the module. Exact-output swaps are not provided. Approvals are exact amount and cleared after selling. Token output is delivered to `recipient`, or retained if it is the executor itself.

`amountUnused` is a buy's actual refunded ETH, rewrapped if `tokenIn` is WETH. It remains in the execution context for the executor to refund; existing balances are excluded. Settlement may return less than the initial ETH because reverse-route fees and price impact apply. A plain buy that overfills the curve reverts. No funds should remain in this public prefunded module between transactions.

The module requires Cancun transient storage. Its named transient reentrancy guard avoids introducing a persistent storage layout into a delegatecalling executor. A standalone adapter accepts ETH callbacks only from the pinned settlement and WETH. A delegatecalling executor must itself accept those callbacks. Nested Uniswap V4 unlock execution is incompatible: call this module outside an existing PoolManager unlock.

All three minima must come from a fresh executable quote as applicable, including the refund floor. Integration must simulate the full transaction. A `minQuote`/`minOutput` of one in a mechanics test is not an acceptable production price-protection policy.

Validation completed locally: 17 unit/fuzz tests (three with 128 cases), plus ten tests on a read-only Robinhood fork at block 82183340. These cover WETH and BOOMER, curve and graduated trades, WETH wrapping, overfill graduation/refund, bad routes and rollback. Unit tests also cover a minimal delegatecalling executor, stale/invalid trades, donated balances, forwarding/rejecting recipients and reentrancy. The real Kyber executor has not yet been tested.

The fork tests explicitly establish the integration boundary: a direct factory trade reverts with `native adapter only`; a normal V4 PoolManager swap reverts with the hook's wrapped `native settlement only` error; an adapter round trip succeeds on the same market. Another fork test performs graduation, a subsequent sell and delivery of the unused ETH through a minimal delegatecalling executor, preserving unrelated balances.

This requires an execution module, not only a V4 pricing-hook registration. The upstream [adapter guidelines](https://github.com/KyberNetwork/ks-dex-adapter-lib#contributing) permit calls to other contracts, and [MachimaAdapter](https://github.com/KyberNetwork/ks-dex-adapter-lib/blob/main/src/adapters/machima/MachimaAdapter.sol) provides an existing example of routing gated swaps through a dedicated router. These are architectural precedents, not evidence that Flywheel is activated in Kyber's deployed executor. No changes to deployed Flywheel contracts are needed for this proposed path.

Run unit tests with Foundry:

```sh
forge test --match-path 'test/adapters/flywheel-fun/FlywheelNativeAdapter.t.sol' --evm-version cancun --use 0.8.30 --fuzz-runs 128
```

Set `FLYWHEEL_READONLY_FORK_URL` to a read-only Robinhood RPC to run `FlywheelNativeFork.t.sol`. The tests only execute transactions in Foundry's local EVM. Fork tests skip explicitly when this variable is missing. No private key is needed.

The companion `kyberswap-dex-lib` contribution includes a portable read-only RPC proxy and runner at `pkg/liquidity-source/flywheel-fun/testdata/runner`. With both contributions checked out as sibling repositories, install that runner's locked npm dependencies and set `FLYWHEEL_RPC_URL` through the environment. Run `node run-forks.cjs adapter` for this suite or `node run-forks.cjs quotes` for the 46 Go quote/execution comparisons. `FLYWHEEL_ADAPTER_LIB_DIR` overrides the sibling checkout path. Upstream writes and signatures are denied; results remain local.

The companion dex-lib contribution implements composite quotes and serialized settlement route bytes, with 46 exact local-fork buy/sell comparisons covering WETH, BOOMER and PONS, graduated markets, graduation refunds, and one- and two-parent native Flywheel routes. Its test harness builds the ABI-encoded Trade payload; Kyber's production calldata builder must populate the minima, deadline and refund fields. Each parent market charges its own fees. This does not validate Kyber's outer execution envelope.

Pending before activation: Kyber's deployed Robinhood executor/router, its refund and delegatecall integration, backend outer calldata integration, routing-engine split routes and shared-pool behavior, measured production gas estimates, and Kyber review/deployment.

Contract ABIs, sources and accounting: https://flywheel.cash/integrations/20261007/index.html
