# execution/zendex

Execution module for the hub. After each netting window, it sends the hub's net flow to ZENDEX, a shielded AMM on Horizen testnet (chain 2651420). It runs at sandbox scale.

## What it does

`agents/run.py` writes one line per epoch to `deployment/netting-log.jsonl`. `execute` then:

1. Settles any relay still pending from a previous run.
2. Reads the epochs after `lastExecutedEpoch` whose net flow the NettingAttestor proved on chain (`attest_tx` in the log). An epoch without a proof is never executed. The first run takes only the last 20.
3. Nets the hub's market flow per asset over that window. Buys count positive and sells negative.
4. Sizes each leg by its USDC notional divided by `SCALE_DOWN` (default 10000). Testnet pools are not priced like exchanges, so a sell spends the amount of token the ZENDEX pools value at that notional, not a scaled quantity.
5. Executes each net leg with shielded notes, routing only through WZEN pairs, as the ZENDEX app does:

| leg | route |
|---|---|
| buy ZEN | deposit tUSDC, swap to WZEN |
| buy BTC | deposit tUSDC, swap to WZEN, swap to tcbBTC |
| sell BTC | mint tcbBTC (testnet mock token), deposit, swap to WZEN, swap to tUSDC |
| sell ZEN | take a WZEN note held in the pool (split to the exact size when larger, otherwise the largest smaller note), swap to tUSDC |
| ETH | skipped: no venue on ZENDEX testnet |

The following legs are skipped and logged:
- legs below `MIN_LEG_USDC` (default 0.5 tUSDC);
- ZEN sells when the pool holds no WZEN inventory.

When the wallet is short of tUSDC, the script mints it with the testnet faucet. Each leg appends one line to `deployment/execution-log.jsonl` with the window, the hub amounts, the sandbox input and output, and the transaction hashes.

## Client flow

The module reproduces the client side of the public app at testnet.zendex.fi:

- **Deposit:** a Noir deposit proof binds the note commitment `H(asset, amount, H(rho, pk))`. `ZendexVaultManager.deposit` is then called from our wallet.
- **Swap:** an inclusion proof shows the note is in the TreeOperator Merkle tree at its epoch. A swap proof spends it and creates the output note. Both proofs go to the ZENDEX relayer, which submits the transaction and pays its gas.
- **Split:** same as swap, with a split proof that turns one note into two of the same asset.

Shared details:
- Proofs are UltraHonk with a keccak transcript, built with `@noir-lang/noir_js` 1.0.0-beta.7 and `@aztec/bb.js` 0.87.0, the same versions the app ships.
- Circuits are not stored in this repository. `fetch-circuits.mjs` downloads the app's current bundle and extracts the compiled circuits. It identifies each circuit by its ABI parameter names and checks the Noir version.

## What is public on chain for a swap

Public:
- input asset and amount;
- output asset and minimum amount;
- the deadline;
- the spent note's nullifier;
- the new note commitment.

Not public:
- which strategy or vault the order comes from (the hub only sends the net flow of the window);
- the wallet that owns the note, since the relayer sends the swap transaction and pays the gas.

Unused input from an exact output swap goes to a fresh recipient address for each swap. These addresses are derived from our Zendex key.

## Commands

```sh
cd execution/zendex
npm ci
node fetch-circuits.mjs           # circuits/<name>.json from testnet.zendex.fi
node zendex.mjs execute --dry-run # show the plan for the next window
node zendex.mjs execute           # run it on testnet
node zendex.mjs status            # settle pending relays
node zendex.mjs balances          # wallet balances and shielded notes
node zendex.mjs faucet tUSDC 100
node zendex.mjs deposit tUSDC 10
node zendex.mjs swap d3 WZEN
node zendex.mjs split d4 0.01
npm test                          # window aggregation unit tests
```

Environment overrides:

| variable | default |
|---|---|
| `SCALE_DOWN` | 10000 |
| `MIN_LEG_USDC` | 500000, in 1e-6 tUSDC |
| `SLIPPAGE_BPS` | 100 |
| `MAX_RELAYS` | 6 per run |
| `FIRST_RUN_EPOCHS` | 20 |
| `NETTING_LOG`, `EXECUTION_LOG` | log file paths |

## State and re-runs

Local state lives in `.state/` and is git ignored. It holds:
- `wallet.json`: the testnet EVM key;
- `zendex-key.json`: the Zendex note key;
- `notes.json`: notes, pending relays and execution progress.

Every deposit and relay is recorded before it is sent, which makes `execute` safe to rerun after a crash:
- A deposit is recovered from its `LeafInserted` event if it reached the chain.
- A relay is reconciled through the relayer status endpoint.
- A note is never spent while a relay that uses it is still pending.
- A window is marked executed only after all of its legs are logged.
