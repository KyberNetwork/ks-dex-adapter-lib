# AGENTS.md

KyberSwap DEX Adapter Lib: per-DEX adapter contracts that ecosystem partners write so the
KyberSwap DEX Aggregator can route through their pools. The README is the partner contract (the
assumptions an adapter may make and the PR requirements). This file records the conventions and
constraints of the repo and the rules reviewers hold an adapter to.

## Commands

```bash
forge fmt                                                       # CI: `forge fmt --check`
forge build --sizes                                             # CI build job
forge test --match-path 'test/adapters/<dex>/*' -vvv            # one adapter's tests
forge test -vvv                                                 # CI test job, needs every RPC
```

- CI installs the latest stable Foundry and runs `forge fmt --check`, `forge build --sizes` and
  `forge test -vvv` with `FOUNDRY_PROFILE=ci`. A fork test against a chain whose `RPC_<chainId>`
  secret is not set in `.github/workflows/test.yml` fails in CI; add the secret to the workflow
  `env` with the test.
- The compiler is `^0.8.0` resolved by Foundry, with `via_ir`, 44,444,444 optimizer runs and EVM
  `osaka`; `ffi` and `dynamic_test_linking` are on. Fuzz runs default to 32.
- `forge fmt` uses `line_length = 100`, `tab_width = 2`, single quotes, thousands separators in
  number literals and sorted imports. Run it before every commit: CI fails on any diff.
- Fork tests read `RPC_<chainId>` from `.env` through the aliases in `foundry.toml` (`mainnet`,
  `base_mainnet`, `hyperevm_mainnet`, ...). A new chain needs an alias there; also add it to
  `multichain_config.toml`, which lists the same endpoints by chain id.

## Layout

| Path | Contents |
|---|---|
| `src/adapters/<dex>/<Dex>Adapter.sol` | One adapter contract per DEX, with an `execute<Dex>` entry point |
| `src/adapters/<dex>/I<Pool>.sol` | Minimal interfaces for the DEX contracts the adapter calls |
| `src/adapters/<dex>/libraries/` | Vendored libraries the adapter needs |
| `src/libraries/TokenHelper.sol` | Transfers, approvals and balances for native and ERC-20 tokens |
| `src/libraries/CalldataDecoder.sol` | Reads the adapter's `data` without `abi.decode` |
| `test/adapters/<dex>/<Dex>Adapter.t.sol` | Fork tests for the adapter |
| `test/helpers/` | Helpers shared by several tests (`HyperEVMFork` for HyperEVM read precompiles) |

`src/adapters/uniswap-v2` and `src/adapters/uniswap-v3` are the reference adapters the README
points partners to.

## Adapter interface

```solidity
function execute<Dex>(
  bytes calldata data,
  uint256 amountIn,
  address tokenIn,
  address tokenOut,
  address recipient
) external payable returns (uint256 amountUnused, uint256 amountOut);
```

- `amountIn` of `tokenIn` is already in the contract when the function runs.
- `amountOut` is the amount of `tokenOut` delivered to `recipient`, or left in the contract when
  the DEX cannot pay a recipient (the executor collects it).
- `amountUnused` is the input the DEX did not take.
- Native tokens use `TokenHelper.NATIVE_ADDRESS` (`0xEeee…EEeE`); `TokenHelper.isNative` also
  accepts `address(0)`. An adapter for a DEX without native support can ignore them.
- Unused parameters stay unnamed (`address, address`), as in `WasabiPropAmmAdapter`.

## How the executor runs an adapter

The executor **delegatecalls** the adapter, so adapter code runs in the executor's context: its
balances, its allowances, its `receive()`, its storage. Never assume the executor's balances start
at zero: it can hold dust or earlier hops' output.

The executor already handles the following, so an adapter must not add them:

- **Output checks.** The executor checks the `tokenOut` amount after each hop and enforces the
  route's minimum output and deadline. Pass `minOut = 1` (or 0) and a deadline of
  `block.timestamp` (or `block.timestamp + 1`) to the DEX.
- **Callback auth.** The executor records which pool may call back and checks it. Don't add a
  caller check, a factory `getPool` check or any state to remember the pool. Adapters are
  stateless: no storage, no immutables that hold per-route data.
- **Callback routing.** The executor dispatches any callback name that takes exactly
  `(int256, int256, bytes)`, so a renamed Uniswap V3-style callback needs nothing special. Any
  other callback signature has to be raised with the Kyber reviewers.
- **Allowances.** The executor holds no funds between routes, so a standing allowance to the pool
  is fine. `tokenIn.forceApprove(pool, amountIn)` is the pattern; don't reset it to 0 afterwards.

## Adapter rules

1. **Trust the DEX.** Take `amountOut` from what the swap returns. Don't measure balances before
   and after to check the DEX: if a DEX can't be trusted to return the right amount, it isn't
   integrated. The exception is a DEX that supports fee-on-transfer (FOT) tokens.
2. **Compute `amountUnused` only when the DEX signals partial use.** If the DEX returns an amount
   used, a refund or a delta, or is documented to refund unspent input, set
   `amountUnused = amountIn - amountUsed` from the return values. Otherwise leave it out.
3. **Put route-time facts in `data`.** Anything known when the route is built (pool, direction
   such as `zeroForOne` or a `kind`, pool tokens, fees) goes in `data` and is read with
   `CalldataDecoder` (`data.decodeAddress(i)`, `data.decodeUint256(i)`, ...), instead of calling
   `token0()`, `token()` and the like on-chain. Direction from `tokenIn < tokenOut` is fine when
   the pool sorts its tokens. Document the encoding in a NatSpec `@param data` or `@dev` line.
4. **No repeated code across branches.** Do shared steps once before branching: approve or
   transfer once, compute `value` once, then make one call. Approval, native handling or the
   swap call copied into each branch is flagged.
5. **Don't repeat the DEX's own checks.** No custom errors for "wrong pair", "unsupported token"
   or "not this curve" when the DEX already reverts on that input.
6. **No `receive()` in the adapter.** Under delegatecall, native tokens from the DEX reach the
   executor's own `receive()`. If a test needs one, it is calling the adapter directly; use a
   delegatecall harness instead (see Tests).
7. **Interact with the pool, not a router**, when the DEX allows it. Implement any swap callback
   in the adapter.
8. **Use the libraries.** `TokenHelper` (`safeTransfer`, `forceApprove`, `balanceOf`,
   `isNative`) for tokens and `CalldataDecoder` for `data`. Don't add OpenZeppelin `SafeERC20` or
   `abi.decode` for the same job.
9. **Keep it small.** Interfaces declare only the functions the adapter and its tests call. Vendor
   libraries into `libraries/` only when the adapter needs them.

An adapter that matches the UniswapV2/V3 pattern and breaks none of these rules needs nothing
more. Don't add defensive checks, events, owners, pausing or upgradeability.

## Style

- Follow the existing adapters: `pragma solidity ^0.8.0;`, relative imports from
  `'../../libraries/...'`, `using TokenHelper for address;` and `using CalldataDecoder for bytes;`.
- Contract `<Dex>Adapter`, entry point `execute<Dex>`, decoding in `_decodeData` when it takes
  more than a line or two.
- NatSpec on the contract and entry point: what the venue is, the `data` encoding, and why
  `amountUnused` is or isn't computed. Comments explain the DEX's behaviour, not the Solidity.
- Keep the partner's own SPDX license and copyright header.

## Tests

- Each adapter has fork tests in `test/adapters/<dex>/` against the live pools, pinned to a block
  with `vm.createSelectFork('<alias>', BLOCK_NUMBER)` so results are reproducible.
- Compare `amountOut` with the DEX's own quote function or preview at the same state, and check
  the recipient's balance change equals the returned `amountOut`.
- Before the swap, put dust of `tokenIn` and `tokenOut` in the contract holding the funds, so the
  test doesn't depend on a zero balance, and assert balance changes rather than absolute balances.
- Run the adapter through a delegatecall harness, as `USCoreTestExecutor` in
  `test/adapters/uscore/USCoreAdapter.t.sol` does, and check balances on the harness.
- Cover every direction, every `kind` or venue the adapter supports, and native and ERC-20 input
  and output where the adapter supports them. Fuzz `amountIn` with `bound` to a sensible share of
  pool reserves; reject infeasible seeds with `vm.assume` rather than returning early.
- To test an internal function, expose it through a test-only contract that inherits the adapter
  (`AmmalgamAdapterHarness`), never by making it `public` in `src`.

## Git and PRs

- Partners fork the repo and open PRs against `main`. The fork must be owned by a user account,
  not an organization, and "Allow edits from maintainers" must be on (see the README).
- One PR per adapter, touching only `src/adapters/<dex>/`, `test/adapters/<dex>/` and, when a new
  chain is needed, `foundry.toml`, `multichain_config.toml` and the CI workflow's RPC env.
- Commit and PR titles use `feat: add <Dex> adapter`, `fix:`, `refactor:`, `test:`, `style:`,
  `chore:` or `docs:`, optionally scoped (`feat(uscore): ...`). Address review feedback in new
  commits rather than force-pushing over them.
- The PR description names the DEX and chain, the pools the tests fork, the `data` encoding and
  how `amountUnused` is handled.
