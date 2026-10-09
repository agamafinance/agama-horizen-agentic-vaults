"""Run the sandbox live on a chain.

  python3 agents/run.py setup     generate strategist keys, fund them, register
  python3 agents/run.py epochs N  run N epochs end to end

One process plays three roles so the demo is self-contained, and keeps them
apart the way they would be in production:

  - each strategist holds its own key, its own book and its own salts, and
    only ever sends a commitment, then a proof
  - the oracle key posts exchange closing prices after each epoch closes
  - nothing else touches the hub

Every transaction hash is appended to deployment/testnet-log.jsonl.
"""

import json
import os
import secrets
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "zk"))
sys.path.insert(0, str(ROOT / "agents"))
import prover  # noqa: E402
from strategies import STRATEGIES  # noqa: E402

DEP = json.loads((ROOT / "deployment" / "testnet.json").read_text())
RPC, HUB = DEP["rpc"], DEP["hub"]
KEYS = ROOT / "agents" / ".keys"
STATE = ROOT / "agents" / "state"
LOG = ROOT / "deployment" / "testnet-log.jsonl"
SCALE = 1_000_000


def oracle_key():
    """The oracle key also funds the strategist keys on testnet. Read from the
    ORACLE_PK environment variable, or from a .env file at the repo root."""
    if os.environ.get("ORACLE_PK"):
        return os.environ["ORACLE_PK"]
    env = ROOT / ".env"
    for line in env.read_text().splitlines() if env.exists() else []:
        if line.startswith("ORACLE_PK="):
            return line.split("=", 1)[1].strip()
    raise SystemExit("set ORACLE_PK, or put ORACLE_PK=... in .env")


def sh(*args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[-400:])
    return r.stdout.strip()


def call(sig, *args):
    return sh("cast", "call", HUB, sig, *map(str, args), "--rpc-url", RPC)


def send(key, sig, *args, what=""):
    out = sh("cast", "send", HUB, sig, *map(str, args), "--private-key", key, "--rpc-url", RPC, "--json")
    tx = json.loads(out)
    entry = {"what": what, "tx": tx["transactionHash"], "status": tx["status"], "gas": int(tx["gasUsed"], 16)}
    with LOG.open("a") as f:
        f.write(json.dumps(entry) + "\n")
    if tx["status"] != "0x1":
        raise RuntimeError(f"{what} reverted: {tx['transactionHash']}")
    return tx["transactionHash"]


def spot_prices(attempts=12):
    """ETH, BTC, ZEN in USD from Binance, CoinGecko as a fallback. A network
    blip retries instead of killing the run: the prices only have to be posted
    after the close, so a late post is fine."""
    for i in range(attempts):
        try:
            return _spot_prices()
        except Exception as e:
            print(f"price fetch failed ({e.__class__.__name__}), retrying in {10 * (i + 1)} s", flush=True)
            time.sleep(10 * (i + 1))
    return _spot_prices()


def _spot_prices():
    try:
        url = 'https://api.binance.com/api/v3/ticker/price?symbols=["ETHUSDT","BTCUSDT","ZENUSDT"]'
        data = {d["symbol"]: float(d["price"]) for d in json.load(urllib.request.urlopen(url.replace('"', "%22"), timeout=10))}
        usd = [data["ETHUSDT"], data["BTCUSDT"], data["ZENUSDT"]]
    except Exception:
        url = "https://api.coingecko.com/api/v3/simple/price?ids=ethereum,bitcoin,zencash&vs_currencies=usd"
        d = json.load(urllib.request.urlopen(url, timeout=10))
        usd = [d["ethereum"]["usd"], d["bitcoin"]["usd"], d["zencash"]["usd"]]
    return [SCALE] + [int(round(x * SCALE)) for x in usd]


def load(name):
    return json.loads((STATE / f"{name}.json").read_text())


def save(name, st):
    STATE.mkdir(exist_ok=True)
    (STATE / f"{name}.json").write_text(json.dumps(st, indent=1))


def setup():
    KEYS.mkdir(exist_ok=True)
    funder = oracle_key()
    for name, cfg in STRATEGIES.items():
        kf = KEYS / f"{name}.json"
        if not kf.exists():
            w = json.loads(sh("cast", "wallet", "new", "--json"))[0]
            kf.write_text(json.dumps({"address": w["address"], "key": w["private_key"]}))
        k = json.loads(kf.read_text())
        sh("cast", "send", k["address"], "--value", "0.0004ether", "--private-key", funder, "--rpc-url", RPC)
        send(k["key"], "register(string,uint8,uint64)", name, cfg["mask"], cfg["cap_bps"], what=f"register {name}")
        sid = int(call("strategyCount()(uint256)").split()[0]) - 1
        save(name, {"id": sid, "book": None, "salt": 0, "started": False, "orders": None})
        print(f"{name}: strategy {sid}, key {k['address']}")


def epochs(n):
    oracle = oracle_key()
    cap = DEP["capital"]
    hist_file = STATE / "prices.json"
    history = json.loads(hist_file.read_text()) if hist_file.exists() else [spot_prices()]
    length = DEP["epoch_length"]

    for _ in range(n):
        e = int(call("currentEpoch()(uint64)").split()[0])
        closes = int(call("closesAt(uint64)(uint64)", e).split()[0])
        if closes - time.time() < min(60, length // 3):  # too close to the bell, take the next one
            time.sleep(max(0, closes - time.time()) + 2)
            e += 1
            closes += length

        # 1. strategists commit before the close
        for name, cfg in STRATEGIES.items():
            st = load(name)
            k = json.loads((KEYS / f"{name}.json").read_text())
            book = st["book"] or [cap, 0, 0, 0]
            orders = cfg["fn"](book, history, cfg["cap_bps"])
            salt = prover.rand_salt()
            oc = prover.order_commit(st["id"], e, orders, salt)
            txh = send(k["key"], "commitOrders(uint256,uint64,bytes32)", st["id"], e, "0x%064x" % oc, what=f"{name} commit e{e}")
            st["pending"] = {"epoch": e, "orders": orders, "salt": salt, "commit": oc}
            save(name, st)
            print(f"e{e} {name}: committed {len(orders)} order(s) as 0x{oc:064x}"[:72] + f"…  tx {txh[:12]}…", flush=True)

        # 2. oracle posts closing prices after the close
        time.sleep(max(0, closes - time.time()) + 3)
        px = spot_prices()
        txh = send(oracle, "postPrices(uint64,uint64[4])", e, "[" + ",".join(map(str, px)) + "]", what=f"prices e{e}")
        print(f"e{e} oracle: ETH {px[1] / SCALE:,.2f} · BTC {px[2] / SCALE:,.2f} · ZEN {px[3] / SCALE:,.3f}  tx {txh[:12]}…", flush=True)
        history.append(px)
        hist_file.write_text(json.dumps(history))

        # 3. strategists prove and settle
        for name, cfg in STRATEGIES.items():
            st = load(name)
            k = json.loads((KEYS / f"{name}.json").read_text())
            p = st["pending"]
            book = st["book"] or [cap, 0, 0, 0]
            new_salt = prover.rand_salt()
            nc, nav, proof, _ = prover.settle(
                strategy_id=st["id"], epoch=e, old_bal=book, old_salt=st["salt"], orders=p["orders"],
                orders_salt=p["salt"], new_salt=new_salt, old_commit=st.get("commit", 0), orders_commit=p["commit"],
                prices=px, allowed_mask=cfg["mask"], max_weight_bps=cfg["cap_bps"],
                is_genesis=not st["started"], genesis_capital=cap, tag=f"{name}_{e}")
            txh = send(k["key"], "settle(uint256,uint64,bytes32,uint64,bytes)", st["id"], e, "0x%064x" % nc, nav,
                       "0x" + proof.hex(), what=f"{name} settle e{e}")
            st.update(book=prover.apply_orders(book, p["orders"], px), salt=new_salt, commit=nc, started=True, pending=None)
            save(name, st)
            print(f"e{e} {name}: proof {len(proof):,} B verified on chain, NAV {nav / SCALE:,.2f} USDC  tx {txh[:12]}…", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "setup":
        setup()
    elif sys.argv[1] == "epochs":
        epochs(int(sys.argv[2]))
