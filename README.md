# Agama agentic vaults

**Private books, public track records. A working start on Horizen RFP 1, private agentic trading vaults.**

Horizen's RFP asks for vaults where automated strategies trade for depositors
"without exposing positions, holdings, or strategy logic onchain", and names
the piece that makes an open strategy venue viable: "confidential execution
paired with verifiable performance attestation". This repository is the
attestation half, running on Horizen testnet today, built before we asked for
anything.

**▶ 2-minute demo: [youtu.be/Sw_V7lslx4s](https://youtu.be/Sw_V7lslx4s)**, the architecture, the hub on the Horizen
explorer, proofs built and verified, a live epoch on testnet, and an attack refused by the verifier.

The full design, what each milestone adds, and how it maps to the RFP line by
line: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

> **Status.** A sandbox, started on 30 September 2026. Strategies trade virtual capital at
> real exchange prices, so every NAV below is proven but none of it is money.
> Since 20 October the hub also nets its strategies every epoch and sends the
> net flow to ZENDEX testnet as private swaps, at sandbox scale. Deposits, the
> ZEN bond and Base liquidity are the next milestone. Nothing is audited.

---

## Architecture

Solid boxes run today on Horizen testnet. Dashed ones are the next milestone.

![Architecture](docs/architecture.png)

The same flow as a Mermaid flowchart:

```mermaid
%%{init: {'theme':'base','themeVariables':{'background':'#ffffff','primaryColor':'#ffffff','primaryTextColor':'#111827','primaryBorderColor':'#374151','lineColor':'#9ca3af','edgeLabelBackground':'#ffffff','tertiaryColor':'#ffffff','clusterBkg':'#ffffff','clusterBorder':'#d1d5db','titleColor':'#111827','fontSize':'16px'}}}%%
flowchart TB
    subgraph offchain["OFF-CHAIN · held by each strategist"]
        direction LR
        STRAT["Strategist agent<br/>any model: quant, rules, AI<br/>keeps its book, orders and salts"]
        PROVER["Prover · Noir + UltraHonk<br/>strategy_epoch circuit<br/>book · fills · mandate · NAV · under 1 s"]
    end

    subgraph inputs[" "]
        direction LR
        FEED["Price oracle<br/>exchange closes on testnet<br/>Stork on mainnet"]
        DEP["Depositors<br/>choose on proven track record"]
    end

    subgraph horizen["HORIZEN L3 · testnet 2651420"]
        direction LR
        HUB["AgentVaultHub<br/>commitOrders · postPrices · settle<br/>book commitments · proven NAV · drawdown"]
        VER["EpochVerifier<br/>UltraHonk · ~2.1M gas"]
        VAULTS["Strategy vaults · ERC-4626<br/>ZEN bond · public ranking"]
    end

    subgraph market["EXECUTION · netting and ZENDEX live on testnet"]
        direction LR
        NET["Netting engine<br/>nets every epoch · executes hourly<br/>proven on chain · v2 Vela enclave"]
        ZENDEX["ZENDEX<br/>private swaps on Horizen"]
        BASE["Base liquidity<br/>via the cluster's private bridge"]
    end

    STRAT -->|"1 · orders hash, before the close"| HUB
    STRAT --> PROVER
    FEED -->|"2 · closing prices, after the close"| HUB
    PROVER -->|"3 · proof, new commitment, NAV"| HUB
    HUB -->|"verify"| VER
    DEP -.-> VAULTS
    VAULTS -.-> HUB
    HUB --> NET
    NET -->|"private swaps, via the ZENDEX relayer"| ZENDEX
    NET -.-> BASE

    classDef actor fill:#eff6ff,stroke:#2563eb,color:#1e40af
    classDef core fill:#ffffff,stroke:#374151,color:#111827
    classDef offchain fill:#fff7ed,stroke:#f97316,color:#c2410c
    classDef feed fill:#faf5ff,stroke:#a855f7,color:#7e22ce
    classDef integration fill:#f0fdf4,stroke:#22c55e,color:#15803d
    classDef next fill:#ffffff,stroke:#9ca3af,color:#6b7280,stroke-dasharray:5 4

    class STRAT,DEP actor
    class HUB,VER core
    class PROVER offchain
    class FEED feed
    class ZENDEX integration
    class NET core
    class VAULTS,BASE next
    style inputs fill:#ffffff,stroke:#ffffff
```

Legend: blue = actor · orange = off-chain component · purple = price feed · green = Horizen app cluster · dark outline = core Agama contract · dashed grey = next milestone.

## What it proves

Each strategy keeps its book off chain. The chain holds a commitment to it and
nothing else. Every epoch runs in an order the contract enforces with time:

1. **Before the epoch closes**, the strategy commits to its orders. Once only.
2. **After it closes**, the oracle posts the closing prices.
3. **The strategy settles** with a proof that its committed orders, filled at
   those prices, move its committed book to a new one that respects its
   mandate, and that the NAV it reports is the value of that book.

What that buys, without trusting the strategy or us:

| A strategy cannot... | because |
|---|---|
| pick its trades with hindsight | orders are fixed before any closing price exists |
| add, drop or resize a trade after the fact | the orders are a public input of the proof, rebuilt by the contract from the commitment |
| report a better NAV | the NAV is an output of the proof |
| invent a starting book | the first epoch starts from a public amount of cash |
| break its mandate | the circuit refuses a book outside the allowed assets or above the weight cap |
| rewrite its history | each proof opens the commitment the previous one produced |

What the chain sees per strategy: its mandate, a commitment, and a proven NAV
with its drawdown. What it never sees: a balance, an order, or the logic that
produced them.

## Live on Horizen testnet

| | |
|---|---|
| AgentVaultHub | [`0x292ED0c07E03Bb4972009Ac2bF1126cD63c1a361`](https://horizen-testnet.explorer.caldera.xyz/address/0x292ED0c07E03Bb4972009Ac2bF1126cD63c1a361) |
| EpochVerifier | [`0x63A1A2bA8a4caDd82e6ff7431b38f695f994AC1f`](https://horizen-testnet.explorer.caldera.xyz/address/0x63A1A2bA8a4caDd82e6ff7431b38f695f994AC1f) |
| NettingAttestor | [`0x44B556a840A684b3533714c96F60e6912F2e3A0e`](https://horizen-testnet.explorer.caldera.xyz/address/0x44B556a840A684b3533714c96F60e6912F2e3A0e) |
| NetVerifier | [`0xb907c33270e07f45264b9B80e3908846c8B842F3`](https://horizen-testnet.explorer.caldera.xyz/address/0xb907c33270e07f45264b9B80e3908846c8B842F3) |

Two strategies run against it in three-minute epochs, on ETH, BTC and ZEN
closing prices from Binance: a momentum strategy and a mean-reversion one.
Read everything a depositor can see, with no key:

```sh
./deployment/read-state.sh
```

### Track record so far

Snapshot of 9 October 2026: 274 settlements verified on chain. Sandbox capital 1,000,000 USDC per strategy. The strategies keep running, so the **[live page](https://agamafinance.github.io/agama-horizen-agentic-vaults/)** is ahead of this table.

| Strategy | Epochs proven | Proven NAV (USDC) | Return | Max drawdown | Last proof |
|---|---|---|---|---|---|
| momentum | 136 | 990,062.51 | -0.994% | 2.04% | [tx](https://horizen-testnet.explorer.caldera.xyz/tx/0x0e3dad3f4f275953ee7aa94dae8adc55105ba596007f2b436fef1dad8e6e176d) |
| mean-reversion | 136 | 951,862.53 | -4.814% | 8.04% | [tx](https://horizen-testnet.explorer.caldera.xyz/tx/0x09c912fd0bc82eb2a7e297985dec4de9c3b00f8749ec04e6a43cdf2416ecb1de) |

The balances behind those numbers, and the orders that moved them, are not on chain.

The strategies are deliberately simple, three-minute epochs and a 40% cap per asset, and they trade real prices: ZEN and ETH dropped and then recovered across the runs, and the record shows both legs, losses published exactly like gains. That is the point of a proven track record: nothing is picked after the fact, and each figure links to the transaction that verified it. The [live page](https://agamafinance.github.io/agama-horizen-agentic-vaults/) ([`docs/index.html`](docs/index.html)) draws the same record straight from the chain.

## Netting and private execution on ZENDEX

The RFP's other half is confidential execution. It runs on testnet since 20 October 2026.

**Netting, every epoch.** Once prices are posted, [`agents/netting.py`](agents/netting.py) crosses opposite orders between strategies at the closing price. Only the residual, one net quantity per asset for the whole hub, goes to market.

**The netting is proven, not trusted.** A second circuit, [`zk/net_epoch`](zk/net_epoch/src/main.nr), opens every strategy's order commitment with the hash the hub stored before the close, and proves the hub's net flow and what was crossed inside the batch. [`NettingAttestor`](contracts/src/NettingAttestor.sol) verifies the proof on chain. It reads the batch from the hub itself, so a strategy that committed cannot be left out, and it refuses to attest before the close, when a commitment could still arrive. The orders stay private: the chain learns the totals only. Each epoch's result and its attestation transaction are appended to [`deployment/netting-log.jsonl`](deployment/netting-log.jsonl).

**Execution, every hour.** [`execution/zendex/`](execution/zendex) sums the net flow of the last 20 epochs and sends it to [ZENDEX](https://testnet.zendex.fi), the shielded AMM on Horizen, as private swaps. Our script runs the same client flow as the ZENDEX app:
- it deposits into the shielded pool with a Noir proof;
- it proves that the note is in the pool's Merkle tree and that the swap is valid;
- it hands both proofs to the ZENDEX relayer, which sends the transaction and pays its gas.

The venue sees the hub's net flow for the hour. It does not see which strategy traded or what each one did, and the swap does not come from our wallet.

One hour of real flow, for example, epoch 9691:

| Hub net flow | Sent to ZENDEX (sandbox scale, 1/10,000) | Transactions |
|---|---|---|
| buy 1.20 BTC, 99,192 USDC | deposit 9.92 tUSDC, swap to WZEN, swap to tcbBTC | [deposit](https://horizen-testnet.explorer.caldera.xyz/tx/0x20cd9f9422d9dae1c3502aca5d7e979f9cb506697fb78157ddacafc3994290c3) · [swap](https://horizen-testnet.explorer.caldera.xyz/tx/0x30184d2567cf4c748ba97287675439bc944b9db2b600db6fef1cc0e834eb0842) · [swap](https://horizen-testnet.explorer.caldera.xyz/tx/0x3016ecd6def38b7b47161115daa10fa90dc589a746394892ed3397b5cd69e9c9) |
| sell 18,283 ZEN, 110,100 USDC | a WZEN note held in the pool, swapped to tUSDC | [swap](https://horizen-testnet.explorer.caldera.xyz/tx/0x313101aa7579a52aeffa67fec462576318bf7c1f62a3a2639348908a0540a1ac) |
| sell 8.48 ETH | not sent: ZENDEX testnet has no ETH market | |

Every leg, executed or skipped, is in [`deployment/execution-log.jsonl`](deployment/execution-log.jsonl). Testnet pools hold faucet tokens at synthetic prices, so each leg is sized by its USDC notional and the fill prices say nothing about a real market. What the sandbox shows is the path: proven books, a netted batch, and private swaps on a Horizen venue, with no strategy visible along the way.

## Attacks, mined on chain

Three attacks sent as real transactions from a separate test strategy, mined, and reverted. Each one was set up so that every check before the targeted one passes, and the revert data was decoded to confirm which check refused it. Details in [`deployment/attacks.json`](deployment/attacks.json).

| Attack | What was sent | Refused by | Mined tx | Then, honestly |
|---|---|---|---|---|
| late orders | orders committed for an epoch that had closed | `EpochClosed` | [tx](https://horizen-testnet.explorer.caldera.xyz/tx/0x2512b5375699e8603d3fc2a408cb885cef8933ec55b7805f0e6d8bc993ca4727) | n/a |
| inflated NAV | a valid proof, with 100,000 USDC added to the NAV beside it | `SumcheckFailed` | [tx](https://horizen-testnet.explorer.caldera.xyz/tx/0x161da98eb45eff75807491520aba414ab17925266e3055cb09737610fce645a4) | [settled](https://horizen-testnet.explorer.caldera.xyz/tx/0x08b709026444ebb205e8ad2d6482609bc87bd148a8a30c0073233f1c363bd9dc) |
| swapped orders | one order set committed, a larger one proven | `SumcheckFailed` | [tx](https://horizen-testnet.explorer.caldera.xyz/tx/0xcf2a3118dbfc69488c6c25efa4d25d1baa6a0f315c521fffc7b2c887074743b9) | [settled](https://horizen-testnet.explorer.caldera.xyz/tx/0x000654bebdcf2300832d6b9befefb40d62d3b9167e346c24314cdf469389bd2e) |

Where the verifier refuses, the same strategy settles honestly right after, with the same proof and the true NAV, or with the orders it actually committed. The attack was the only thing wrong. The full transaction log of the run is in [`deployment/testnet-log.jsonl`](deployment/testnet-log.jsonl).

## Check it yourself

Nothing here needs trusting us. From a clean checkout:

```sh
./zk/prove.sh                          # rebuild circuits, verifier and proofs from source
git status                             # stays clean: the committed artefacts are what the source produces
cd contracts && forge test && cd ..    # 19 tests against real proofs
python3 deployment/verify-bytecode.py  # the deployed contracts are this code, immutables included
./deployment/read-state.sh             # every public fact, keyless
python3 deployment/report.py           # the tables above, rebuilt from chain data
```

## Layout

| Path | What |
|---|---|
| `zk/strategy_epoch/` | the settlement circuit, Noir, with its own tests |
| `zk/net_epoch/` | the netting circuit: the hub's net flow from every committed order set |
| `zk/order_commit/` | off-chain helper that computes an order commitment with the same hash |
| `zk/prover.py` | nargo + bb wrapper: commit, execute, prove (UltraHonk, keccak transcript) |
| `zk/prove.sh` | rebuilds every circuit artefact from source |
| `contracts/src/AgentVaultHub.sol` | registry, order commitments, closing prices, proven settlement |
| `contracts/src/NettingAttestor.sol` | records each epoch's proven net flow, reading the batch from the hub |
| `contracts/src/EpochVerifier.sol`, `NetVerifier.sol` | generated by `bb write_solidity_verifier` |
| `contracts/test/` | the honest path and every refusal, against real proofs |
| `agents/` | the two strategies, the live runner, the netting, the attack script |
| `execution/zendex/` | sends each hour's net flow to ZENDEX as private swaps |
| `deployment/` | addresses, transaction log, public state reader, bytecode check, report |
| `docs/` | architecture and milestones, the diagrams (Mermaid source and rendered), the live track record page |

Settlement costs about 2.1M gas, most of it the UltraHonk verifier, which is a
fraction of a cent on Horizen. Proving takes under a second on a laptop.

## What comes next

Netting and ZENDEX execution run today. The next milestone adds:

- **fills allocated back per strategy**, so each book is settled at the
  execution price of the netted batch, not only at the closing price
- **vaults with real deposits**, one ERC-4626 per strategy, priced at the
  proven NAV
- **the strategy lifecycle** the RFP asks about: sandbox, incubation, open,
  with a public ranking computed from proven figures and a strategist bond in
  ZEN sized to the capital a strategy may manage
- **execution at real size**: ZENDEX mainnet, and Base liquidity for assets
  Horizen does not list, starting with ETH
- **operator blindness**: netting inside a Vela enclave once Vela runs on
  Horizen with hardware attestation

## Built on

The proving pipeline, the commit-before-outcome pattern and the testing
discipline come from our earlier Horizen work,
[agamafinance/agama-horizen](https://github.com/agamafinance/agama-horizen),
where the same approach attests a private credit book on Horizen testnet.
