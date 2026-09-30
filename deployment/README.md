# deployment

| | |
|---|---|
| `testnet.json` | addresses and parameters on Horizen testnet (chain 2651420) |
| `read-state.sh` | everything a depositor can see, with eth_call only and no key |
| `verify-bytecode.py` | checks the deployed code is exactly what this repo compiles, immutables included |
| `report.py` | builds the README's results and attacks tables from chain data |
| `attacks.json` | the three attacks, their transactions and the decoded refusals |
| `testnet-log.jsonl` | every transaction of the 13-epoch run |
| `run-12.log`, `attacks.log` | console output of the runs |
