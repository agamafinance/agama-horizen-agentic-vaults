# agents

| | |
|---|---|
| `strategies.py` | two sandbox strategies, momentum and mean reversion. Deliberately simple: the demo is about what stays private and what gets proven, not about edge. |
| `run.py` | runs epochs live: each strategist commits, the oracle posts prices, each strategist proves and settles |
| `attacks.py` | sends three attacks as real transactions from a separate strategy, then settles honestly |

```sh
export ORACLE_PK=0x...          # oracle key, also funds strategist keys on testnet
python3 agents/run.py setup     # generate strategist keys, fund, register
python3 agents/run.py epochs 12
python3 agents/attacks.py       # while run.py is posting prices
```

Strategist keys and books live in `agents/.keys/` and `agents/state/`, both
git-ignored: in production they never leave the strategist.
