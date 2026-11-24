# Efficient PropAMM listing adapter

Executes exact-input trades of an Efficient PropAMM listing, using input already held by the adapter, either through the listing's own door or through the front the listing trades on. Each listing has its own door: one contract, one pair (`TOKEN0`, `TOKEN1`), either direction. Output is paid directly to the supplied recipient; unused input is zero on success, since every route fills the whole input or reverts. Native ETH is unsupported.

A listing's door sits at a CREATE2 address its door factory derives from the listing id (`doorOf(listing)`). The companion `efficient-prop` source lists one pool per door, with the door as the pool address, and carries the door, the front, the listing and the fill mode in the pool's data. It lists a listing only where its maker's desk contract is in its config's `approvedDesks`, which is empty by default.

| Contract | Ethereum mainnet |
|---|---|
| Front (proxy) | [0x0000000000403aeB66691063CC2fD42E71d6AcD6](https://etherscan.io/address/0x0000000000403aeB66691063CC2fD42E71d6AcD6) |
| Listing-door factory | [0x39eD9993449C96503f6a629cCD2BB5F132D7cc93](https://etherscan.io/address/0x39eD9993449C96503f6a629cCD2BB5F132D7cc93) |

No listing is registered on this front yet, and the build is not deployed on Base.

## Data and fill modes

Encode `data = abi.encode(door, front, listing, mode)`: four words, the listing a 24-bit id. The data is the companion source's own, so the adapter decodes its words as they are and validates none of them: mode 0 fills through the door and any other value through the front.

- **Mode 0, the door.** The adapter approves the door for exactly `amountIn` and calls its pull entry, `swapFrom(tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp)`. The door pulls exactly that amount, so the approval ends at zero.
- **Mode 1, the front.** The adapter reads `front.payPoolOf(listing)`. The read stays on chain, not in `data`: the front's answer for a listing changes when the listing's operator sets or clears its credit mode (`setCreditMode`), and the paid entry refuses a listing whose credit mode was set after the answer, so a route built on an earlier answer would revert whole.
  - Where it names a pool (a listing with no credit mode), the adapter transfers `amountIn` to that pool and calls the paid entry, `swapExactInPaid(tokenIn, tokenOut, amountIn, 1, recipient, block.timestamp, listing)`, in the same frame with no call between. No approval is given. The front proves the payment by the pool's balance, so a fee-on-transfer input, which lands short, reverts the hop unless the pool holds untracked balance that covers the fee.
  - Where it is zero, the adapter approves the front for exactly `amountIn` and calls the named entry, `swapSender`, with the same arguments. The front pulls exactly that amount, so the approval ends at zero.

The door is a forwarder to the front's own two entries, so a fill pays the same output and meets the same refusals in either mode. Measured through this adapter's call frame on a fork of Ethereum holding the deployed build, mode 1 spends 29,785 to 32,931 gas less a fill before refunds, and 9,885 to 13,031 less at the receipt (mode 0 earns one refund more, the door's allowance). Mode 0 stays for an executor that will only approve a contract that cannot change: a door is immutable, where the front is a proxy.

The door and the front validate the pair and refuse a size the listing does not fill now with the listing's own error, which reverts the whole route; the adapter neither catches nor rewrites it. The enclosing Kyber router must enforce its overall minimum output and deadline: the adapter passes a minimum output of 1 and this block's timestamp. The adapter reads neither token symbols nor decimals, and does not support fee-on-transfer or rebasing tokens.

## Limits

- **The block.** On Ethereum a listing fills only in a block in which its maker's update landed ahead of the fill; a builder places it there. In any other block the door quotes no size (`NoFill`) and a fill reverts with the front's `NoWord()` (or, the block after a quote that carries, `StalePull()` or `AnchorExpired()`), and the taker pays the gas used up to the revert. The companion source quotes a listing for its next block alone.
- **The tip cap.** A listing may cap the priority fee per gas it fills at, and a fill above the cap reverts with `TipCapped()`. On Ethereum a cap of 0 means no cap. The companion source carries each listing's cap in the pool's meta (`tipCapWei`) and leaves out a listing whose nonzero cap is under its config's `minTipCapWei` (2 gwei by default on Ethereum). A route sent with a tip above a listed cap still reverts.
- **Price sources and tokens.** A listing may read a price source, a contract its operator binds, whose code runs inside the quote and again inside the fill and can tell the two apart. The companion source serves such a listing only where every source it reads is on its config's approved list, which is empty by default. The same holds for a listing's two tokens, which neither the adapter nor the source screens: route through a listing only where its tokens' code cannot change and moves exactly the amounts asked.
- **Gas limits.** The least gas limit that let a fill through this adapter was 21% to 29% above the gas its receipt reports, since each call down to the pool and its lending venue forwards at most 63/64 of the gas left. Set a route's limit at 1.3 times its expected gas or more.

On Ethereum each settled fill logs one `Swapped` at the listing's quote contract, with the front's caller as `sender` (the door through mode 0, the adapter's caller frame through mode 1).

## Tests

Two fuzzed fork tests, one per mode (`test_door`, `test_front`), each over both directions of a listing's pair. A test draws a door and a size, asks the door's own `quote` on the state it executes against, fills that size through the adapter and checks that the fill pays exactly the quote, takes the whole input, pays the recipient and leaves no allowance behind (to the door, the front or the paid pool). A size the quote refuses is redrawn (`vm.assume(false)`). With two doors or more, `test_front_coversBothEntries` checks that the set holds a listing the front names a pool for and one it names none for (a listing with a credit mode).

The tests are skipped unless `RPC_1`, `EFFICIENT_PROP_DOOR` (one door or several separated by commas) and `EFFICIENT_PROP_BLOCK` are set, the last a block in which the listings' maker's update landed. With no listing registered on mainnet there is no public block to pin, so they skip in CI; they pass on a local fork of Ethereum holding the deployed build with four listings (wstETH/WETH with a credit mode, wstETH/USDC, wstETH/USDT and USDT/USDC).

```sh
RPC_1=<Ethereum RPC> EFFICIENT_PROP_DOOR=<door>[,<door>] EFFICIENT_PROP_BLOCK=<block> \
  forge test --match-path 'test/adapters/efficient-prop/*' -vv
```
