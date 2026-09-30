"""Thin wrapper around nargo and bb.

Two jobs, one per circuit:

  order_commit()  the hash a strategy posts before an epoch closes
  settle()        execute strategy_epoch and prove it with UltraHonk (keccak
                  transcript, the flavour the Solidity verifier expects)

Everything goes through the CLIs so the artefacts are exactly the ones
`prove.sh` builds and the contracts verify.
"""

import os
import re
import secrets
import subprocess
from pathlib import Path

ZK = Path(__file__).resolve().parent
ENV = dict(os.environ, PATH=f"{Path.home()}/.nargo/bin:{Path.home()}/.bb:{os.environ['PATH']}")
K = 4
FIELD_MODULUS = 21888242871839275222246405745257275088548364400416663239198124012602088286593


def rand_salt() -> int:
    return secrets.randbelow(FIELD_MODULUS)


def _toml(d: dict) -> str:
    def val(v):
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, (list, tuple)):
            return "[" + ", ".join(val(x) for x in v) + "]"
        if isinstance(v, dict):
            return "{ " + ", ".join(f"{k} = {val(x)}" for k, x in v.items()) + " }"
        return f'"{v}"'
    return "\n".join(f"{k} = {val(v)}" for k, v in d.items()) + "\n"


def _run(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, env=ENV, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError((r.stdout + r.stderr).strip().splitlines()[-1] if (r.stdout + r.stderr).strip() else "failed")
    return r.stdout + r.stderr


def _pad(orders):
    orders = list(orders)[:K]
    while len(orders) < K:
        orders.append({"asset": 0, "side": 0, "qty": 0})
    return orders


def order_commit(strategy_id: int, epoch: int, orders, salt: int) -> int:
    o = _pad(orders)
    d = ZK / "order_commit"
    (d / "Prover.toml").write_text(_toml({
        "strategy_id": strategy_id, "epoch": epoch,
        "assets": [x["asset"] for x in o], "sides": [x["side"] for x in o],
        "qtys": [x["qty"] for x in o], "salt": salt,
    }))
    out = _run(["nargo", "execute", "oc"], d)
    return int(re.search(r"Circuit output: (0x[0-9a-f]+)", out).group(1), 16)


def settle(*, strategy_id, epoch, old_bal, old_salt, orders, orders_salt, new_salt,
           old_commit, orders_commit, prices, allowed_mask, max_weight_bps,
           is_genesis, genesis_capital, tag):
    """Execute and prove one epoch. Returns (new_commit, nav, proof, public_inputs)."""
    d = ZK / "strategy_epoch"
    (d / "Prover.toml").write_text(_toml({
        "old_bal": old_bal, "old_salt": old_salt,
        "orders": [{"asset": x["asset"], "side": x["side"], "qty": x["qty"]} for x in _pad(orders)],
        "orders_salt": orders_salt, "new_salt": new_salt,
        "strategy_id": strategy_id, "epoch": epoch,
        "old_commit": old_commit, "orders_commit": orders_commit,
        "prices": prices, "allowed_mask": allowed_mask, "max_weight_bps": max_weight_bps,
        "is_genesis": bool(is_genesis), "genesis_capital": genesis_capital,
    }))
    out = _run(["nargo", "execute", f"w_{tag}"], d)
    m = re.search(r"Circuit output: \((0x[0-9a-f]+), (0x[0-9a-f]+|\d+)\)", out)
    new_commit, nav = int(m.group(1), 16), int(m.group(2), 0)
    pdir = d / "target" / f"proof_{tag}"
    _run(["bb", "prove", "--scheme", "ultra_honk", "--oracle_hash", "keccak",
          "-b", "target/strategy_epoch.json", "-w", f"target/w_{tag}.gz", "-o", str(pdir)], d)
    return new_commit, nav, (pdir / "proof").read_bytes(), (pdir / "public_inputs").read_bytes()


def apply_orders(bal, orders, prices):
    """Mirror of the circuit's fill logic, so an agent can see its book."""
    b = list(bal)
    for o in orders:
        if o["qty"] == 0:
            continue
        cash = o["qty"] * prices[o["asset"]] // 1_000_000
        if o["side"] == 0:
            b[0] -= cash
            b[o["asset"]] += o["qty"]
        else:
            b[o["asset"]] -= o["qty"]
            b[0] += cash
    return b
