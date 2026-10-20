# Architecture and milestones

This document describes the full protocol this repository is the start of,
what is already running, and what each milestone adds. It follows the order of
Horizen's RFP 1, private agentic trading vaults.

![Architecture](architecture.png)

## The RFP, line by line

| The RFP asks for | How the design answers |
|---|---|
| automated strategies (quant, rules, AI agents) trading for depositors | one vault per strategy; depositors choose a strategy, the strategy trades that vault's capital **(running: three vaults, one of them an AI agent, open to any wallet)** |
| not exposing strategy logic on chain | logic never reaches the chain: the strategist runs its model on its own infrastructure and only sends orders to the netting operator **(running: the AI agent's prompt is not in this repository)** |
| not exposing positions or holdings | each strategy's book is private and only committed to on chain; assets sit in a shared pool, so the chain sees a total, never a strategy's share |
| a strategy that cannot be reverse-engineered from its trade history | orders are batched per epoch and netted across strategies; only the net order reaches the market |
| verifiable performance attestation | every epoch, a ZK proof that the new book is the old book plus its fills, that the mandate holds, that the NAV is the value of that book at posted prices, and that deposits and redemptions are priced at that NAV **(running)** |
| where strategies come from, how they are onboarded and ranked | open registration with a ZEN bond; a sandbox the strategist seeds, then open to depositors; a public ranking computed from proven figures only **(running; the SDK for outside strategists is M1, see [STRATEGISTS.md](STRATEGISTS.md))** |
| how the protocol accrues fees | a performance fee above a high-water mark, in shares, split between strategist and protocol **(running)**; an execution fee on routed volume and a share of the saving from internal netting (M1) |
| integration with the cluster's private venues and with Base liquidity | the proven net order executes on ZENDEX on Horizen **(running, hourly private swaps through its relayer)**, or against Base liquidity through a private bridge (M1) |
| ZEN in the tokenomics | a strategist bond in ZEN that sets the capital a vault may manage and is slashed if it stops proving **(running)**, and a share of protocol revenue to ZEN staking (mainnet) |
| Horizen as the privacy coordination and execution layer | books, orders, proofs, ranking, bonds and fees live on Horizen; Base provides liquidity only |

## One epoch

1. Strategists send encrypted orders. The hash of each order set is committed on chain before the epoch closes. **(running)**
2. After the close, the oracle posts closing prices. **(running, exchange prices on testnet, Stork on mainnet)**
3. The netting engine crosses opposite orders between strategies at the closing price. **(running, with a proof the NettingAttestor verifies on chain)**
4. The net order executes once, on ZENDEX or against Base liquidity. Fills are allocated back per strategy. **(running on ZENDEX testnet, hourly, at sandbox scale; allocation back per strategy is M1)**
5. Proofs: one for the netting, one per strategy for its book, mandate and NAV. **(both running)**
6. Per strategy, the chain records a new commitment, a NAV per share, a drawdown and a mandate check, and prices the epoch's deposits and redemptions at that NAV. **(running)**
7. The contract enforces the guards on its own: a drawdown beyond the declared limit freezes the vault, and a vault that holds deposits and stops proving can be slashed by anyone. **(running)**

## Who sees what

| | Public | Netting operator (v1) | Strategist | Depositor |
|---|---|---|---|---|
| strategy logic | no | no | yes | no |
| orders | a hash | yes | its own | no |
| a strategy's holdings | a commitment | yes | its own | no |
| pool total | yes | yes | yes | yes |
| NAV, drawdown, mandate check | yes | yes | yes | yes |
| the net order sent to market | yes, not attributable | yes | no | no |

**Trust model, stated plainly.** In v1, correctness is proven and needs no
trust, but the netting operator sees orders in order to net them. In v2 netting
moves into a Vela enclave, so no one sees them, and the proofs stay as a second
line of defence.

**A leak most designs miss.** Frequent public returns on a small asset set let
anyone regress a strategy's exposures. Public figures are therefore published
at a lower frequency, with detail at full frequency for depositors and auditors
through a viewing key. Solvency and mandate checks stay per epoch.

## Strategy lifecycle

1. **Sandbox.** The strategist seeds its own vault, and only the strategist
   can deposit, for the first 20 proven epochs. Commit-before-outcome and
   proofs are exactly as in production. **(running)**
2. **Open.** After that, anyone can deposit up to the vault's capacity, which
   its ZEN bond sets. **(running)**
3. **Incubation tiers** between the two, with capacity also scaling with the
   proven record, are M1.

The capital a strategy may manage scales with its ZEN bond and its proven
record. The mandate cannot be broken, the proof forbids it, so the bond covers
what the proof cannot: a strategy that understated its risk and breaches the
drawdown it declared.

## Milestones

| | Scope | Evidence of completion |
|---|---|---|
| **M0, done** | per-strategy proof of book, mandate and NAV; commit-before-outcome; vaults with depositors, shares priced at the proven NAV, an asynchronous redemption queue; ZEN bond with capacity and slashing; performance fee; sandbox then open; drawdown freeze; three live vaults including an AI agent; netting every epoch, proven on chain by its own circuit; the proven net flow sent hourly to ZENDEX testnet as private swaps through its relayer; a first hub with 136+ proven epochs per strategy since 30 September; attacks refused on chain and in 32 tests against real proofs | this repository, `deployment/verify-bytecode.py`, `deployment/read-state.sh`, the live page |
| **M1, the hard part** | strategist SDK with encrypted order handoff, the bond answering for withheld orders; two or more outside strategists running their own vaults; fills allocated back per vault at the batch's execution price; Base execution for ETH; incubation tiers; ERC-7540 interface on the vaults; a public attack suite covering every guard, mined on chain | public repository, source-verified contracts, keyless state reader, transaction hashes |
| **M2, audit** | contracts and Noir circuits audited by a Foundation-approved auditor; fixes; public report | the report |
| **M3, mainnet usage** | mainnet launch tied to ZENDEX mainnet, or a fixed date with Base execution if ZENDEX is not live; three months measured on the RFP's metrics: execution volume routed, active strategies with external depositors, unique depositors, total deposited, fee revenue | on-chain figures |

## Known limits

- v1 netting operator sees orders (closed in v2 by Vela). Today it runs the three vaults itself.
- Testnet custody: books are valued at exchange prices and deposits are held by the hub as tUSDC; only the net flow trades for real, on ZENDEX at 1/100 scale. At mainnet the book's positions are the assets the net orders buy.
- A vault that commits and withholds its orders blocks the netting proof for that epoch; the SDK ties order handoff to the bond.
- Epoch-based, so medium-frequency strategies, not high-frequency trading.
- The starting asset set is what bridges to Horizen: USDC, ETH, BTC, ZEN.
- The pool total is public; a minimum number of active strategies per pool keeps it from describing a single one.
- Books have a fixed number of assets per circuit; recursive aggregation comes later.
