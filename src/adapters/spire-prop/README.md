# Spire proprietary AMM adapter

Executes exact-input trades between any listed base ERC20 and the supplied Spire entrypoint's quote token, using input already held by the adapter. WETH–USDC on Base is the deployment covered by the fork tests below. Output is paid directly to the supplied recipient; unused input is zero on success. Native ETH is unsupported.

Adding another base/quote pair on the same deployment requires listing the base and configuring it in the off-chain source; the adapter accepts that base through its existing payload. All bases on one entrypoint share its quote token. A deployment with a different quote token uses a different entrypoint. The adapter reads neither token symbols nor decimals, and does not support fee-on-transfer or rebasing tokens.

[Protocol overview](https://docs.baibai.cx/takers/overview) · [Quoting and swapping](https://docs.baibai.cx/takers/quoting-and-swapping) · [Deployments](https://docs.baibai.cx/takers/deployments).

| Contract | Base mainnet |
|---|---|
| Entrypoint / approval target | [0x98c1D9E102Eb2806D902b13186BDc7892aC4fFBa](https://basescan.org/address/0x98c1D9E102Eb2806D902b13186BDc7892aC4fFBa#code) |
| Curve book | [0x604d9b9eB1e1571C78661a6C1088427EC9c8c6E5](https://basescan.org/address/0x604d9b9eB1e1571C78661a6C1088427EC9c8c6E5#code) |
| Custodian | [0xAaC48FEB93c5C97E0fb3c7C57E1633922A4ACDa3](https://basescan.org/address/0xAaC48FEB93c5C97E0fb3c7C57E1633922A4ACDa3#code) |

Encode `data = abi.encode(entrypoint, base)` as exactly two ABI address words (64 bytes). These correspond to `entrypoint` and `base` returned in the companion `spire-prop` simulator metadata. `tokenIn` and `tokenOut` must be opposite sides of the base/entrypoint-quote pair.

The adapter approves the exact input amount, calls `swapExactAmountIn(base, tokenIn, amountIn, 1, recipient)`, and returns the recipient's actual output balance increase. The enclosing Kyber router must enforce its overall minimum output and deadline. The venue enforces its own curve expiry and available output custody, consumes the complete input, and provides no independent caller deadline argument. Quote with fresh state and simulate the complete enclosing route before submission.

The tests fork [Base block 50979793](https://basescan.org/block/50979793) and compare output to the deployed curve, checking recipient/custody balances and fill sequence in both directions. They cover repeated consumption, expiry and custody rollback, malformed data, invalid pairs, native value and zero input. The full suite can use `RPC_1` for an Ethereum archive endpoint and `RPC_8453` for Base:

```sh
RPC_1=<Ethereum archive RPC> RPC_8453=<Base RPC> forge test -vv --gas-report
forge fmt --check
```

The enclosing production Kyber router is outside this repository's adapter tests.
