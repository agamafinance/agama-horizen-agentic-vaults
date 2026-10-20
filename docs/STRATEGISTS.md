# Running a strategy vault

Anyone with a model can run a vault: a quant model, a set of rules, or an AI
agent. The hub never sees the model. It sees a mandate, commitments, proofs, and
the vault's capital flows.

## What you write

A strategy is a function. It gets its own book and the public closing prices,
and returns up to four orders for the next epoch. Units match the circuit:
quantities in millionths of an asset, prices in millionths of a USDC.

```python
def my_strategy(book, history, cap_bps):
    """book: [USDC, ETH, BTC, ZEN] held. history: closing prices, one list per epoch."""
    now, prev = history[-1], history[-2]
    if now[1] > prev[1] and book[0] > 0:  # ETH went up: put 10% of the cash in
        return [{"asset": 1, "side": 0, "qty": book[0] // 10 * 1_000_000 // now[1]}]
    return []
```

The three vaults live today are this kind of function:
- [`momentum`](../agents/strategies.py) and [`mean-reversion`](../agents/strategies.py): rules of a few lines.
- [`ai-agent`](../agents/agent.py): a language model asked every half hour for target weights.

The agent's prompt is its edge. The harness reads it from
`agents/.private/agent-prompt.md`, which git ignores, so it never leaves the
strategist's machine. This repository only carries
[an example prompt](../agents/agent-prompt.example.md).

## What stays on your machine

Your book, your order salts, your keys, and your model or prompt. Each epoch
the runner ([`agents/vaults.py`](../agents/vaults.py)) does the following:

1. Before the close, it commits a hash of your orders.
2. After the close, it proves with `zk/vault_epoch` that:
   - your committed orders, filled at the posted prices, move your committed book to a new one;
   - the new book stays inside your mandate;
   - the NAV it reports is that book's value;
   - the epoch's redemptions are paid in cash at that NAV per share.

## Joining

1. **Register with a ZEN bond.** `register(name, assets, max weight per asset, max drawdown, bond)`. The bond sets the vault's capacity: today 10,000,000 tUSDC per ZEN on testnet, where ZEN is scarce. On mainnet the ratio follows the ZEN price.
2. **Sandbox.** For the first 20 proven epochs, only you can deposit. You seed your own vault and build a proven record with your own money.
3. **Open.** After that, anyone can deposit up to the capacity. Depositors choose on proven figures only.

## How vaults are ranked

The live page ranks vaults by proven return and shows each vault's maximum
drawdown and proven epochs. Every one of those figures comes from a verified
proof. A vault's own claims about itself carry no weight.

## What the contract enforces on its own

| If a vault... | then |
|---|---|
| reports a NAV its book does not give | the proof fails |
| skips a deposit or short-pays a redemption | the proof fails: flows are public inputs the contract fills in |
| loses more than its declared maximum drawdown | it freezes: no new orders or deposits; depositors exit at the last proven NAV |
| holds depositors' money and stops proving for 20 epochs | anyone can slash it: the bond goes to the treasury, the vault freezes, depositors exit |
| has no depositors left | the strategist may retire and take the bond back |

## Fees

There is a 10% performance fee on gains above the high-water mark. It is taken
in new shares at settlement, before that epoch's deposits are priced. Half goes
to the strategist and half to the protocol treasury. On mainnet the protocol's
share funds ZEN staking.

## Today's limits

- **Order handoff.** The netting proof covers every vault that committed. To build it, the operator needs each vault's orders and salts, so today the operator runs the three vaults. The next milestone adds the strategist SDK: orders sent encrypted to the netting operator, and later to a Vela enclave. A vault that commits but withholds its orders would block the netting proof for that epoch, so the SDK ties order handoff to the bond.
- **Custody.** On testnet a vault's book is valued at exchange prices, and its deposits are held as tUSDC by the hub. The net flow is executed for real on ZENDEX, at 1/100 scale because its testnet pools are small. At mainnet the book's positions are the assets the net orders buy.
