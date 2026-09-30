# zk

| | |
|---|---|
| `strategy_epoch/` | the settlement circuit: opens the committed book, checks the orders against their commitment, fills them at the posted prices, enforces the mandate, outputs the new commitment and the NAV. Tests in `src/main.nr`. |
| `order_commit/` | the same order hash, as a standalone program, so a strategist can compute its commitment before the epoch closes. Never goes on chain. |
| `prover.py` | runs nargo and bb (UltraHonk, keccak transcript, the flavour the Solidity verifier expects) |
| `fixtures.py` | builds the two chained proofs the Foundry tests replay |
| `prove.sh` | rebuilds everything above from source. On a clean checkout `git status` stays clean afterwards. |

Toolchain: nargo 1.0.0-beta.13, bb 0.87.0.

Public inputs, in the order the hub rebuilds them: `strategy_id, epoch,
old_commit, orders_commit, prices[4], allowed_mask, max_weight_bps, is_genesis,
genesis_capital`, then the two outputs `new_commit, nav`.
