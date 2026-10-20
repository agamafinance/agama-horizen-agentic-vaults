"""Live runner for the v2 vaults on Horizen testnet: strategies with depositors.

  python3 agents/vaults.py setup        # keys, ZEN bonds, registration, seed tUSDC
  python3 agents/vaults.py epochs N     # run N epochs

Each epoch, for every vault: read the redemptions due this epoch, commit
orders before the close (a vault with redemptions due sells pro rata to raise
the cash, so its weights do not move), post the closing prices, prove the
hub's net flow with the NettingAttestor, then settle each vault with a
vault_epoch proof that also prices that epoch's deposits and pays its
redemptions. The strategist seeds its own vault in the sandbox and claims its
shares; anyone else deposits from the live page once the vault is open.

Same helpers and toolchain checks as agents/run.py.
"""

import json
import secrets
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run  # noqa: E402
from run import prover, sh, spot_prices, oracle_key, SCALE  # noqa: E402
import agent  # noqa: E402
import netting  # noqa: E402
from strategies import momentum, mean_reversion  # noqa: E402

ROOT = run.ROOT
V2 = json.loads((ROOT / "deployment" / "testnet-v2.json").read_text())
RPC, HUB = V2["rpc"], V2["vault_hub"]
STATE = ROOT / "agents" / "state"
KEYS = ROOT / "agents" / ".keys"
run.LOG = ROOT / "deployment" / "vaults-log.jsonl"  # transaction log of the v2 run
NET_LOG = ROOT / "deployment" / "vaults-netting-log.jsonl"

BOND = "0.005ether"  # WZEN, the wrapped ZEN ZENDEX pairs with
SEED = 10_000_000_000  # 10,000 tUSDC the strategist puts in its own vault
STRATEGY_TUPLE = "strategy(uint256)((address,uint8,uint64,uint64,bytes32,uint64,bool,bool,uint64,uint64,uint64,uint64,uint64,uint64,uint32,uint256,string))"

VAULTS = {
    "momentum": {"fn": momentum, "mask": 0b0110, "cap_bps": 4_000, "max_dd_bps": 2_500},
    "mean-reversion": {"fn": mean_reversion, "mask": 0b1010, "cap_bps": 4_000, "max_dd_bps": 2_500},
    "ai-agent": {"fn": None, "mask": 0b1110, "cap_bps": 4_000, "max_dd_bps": 2_500},
}
VAULTS["ai-agent"]["fn"] = agent.make(VAULTS["ai-agent"]["mask"], VAULTS["ai-agent"]["cap_bps"])


def call(sig, *args, to=HUB):
    return sh("cast", "call", to, sig, *map(str, args), "--rpc-url", RPC)


def send(key, sig, *args, what="", to=None, value=None):
    to = to or HUB  # the v2 hub unless told otherwise; run.send alone would target v1
    if value is None:
        return run.send(key, sig, *args, what=what, to=to)
    out = sh("cast", "send", to, sig, *map(str, args), "--value", value, "--private-key", key, "--rpc-url", RPC, "--json")
    return json.loads(out)["transactionHash"]


def num(out):
    return int(out.split()[0])


def chain_strategy(sid):
    t = call(STRATEGY_TUPLE, sid).strip()[1:-1]
    f = [x.strip() for x in t.split(", ")]
    return {"book": f[4], "started": f[6] == "true", "frozen": f[7] == "true", "nav": num(f[8]),
            "total_shares": num(f[9]), "share_price": num(f[10]), "epochs": num(f[14])}


def load(name):
    return json.loads((STATE / f"v2-{name}.json").read_text())


def save(name, st):
    tmp = STATE / f"v2-{name}.json.tmp"
    tmp.write_text(json.dumps(st, indent=1))
    tmp.replace(STATE / f"v2-{name}.json")


def key(name):
    return json.loads((KEYS / f"v2-{name}.json").read_text())


# ------------------------------------------------------------------- setup

def setup():
    KEYS.mkdir(exist_ok=True)
    STATE.mkdir(exist_ok=True)
    funder = oracle_key()
    for name, cfg in VAULTS.items():
        kf = KEYS / f"v2-{name}.json"
        if (STATE / f"v2-{name}.json").exists():
            print(f"{name}: already registered")
            continue
        if not kf.exists():
            w = json.loads(sh("cast", "wallet", "new", "--json"))[0]
            kf.write_text(json.dumps({"address": w["address"], "key": w["private_key"]}))
        k = key(name)
        bond = num(call("balanceOf(address)(uint256)", k["address"], to=V2["zen"]))
        if bond == 0:  # a rerun after a failed registration keeps the bond already wrapped
            sh("cast", "send", k["address"], "--value", "0.0065ether", "--private-key", funder, "--rpc-url", RPC)
            send(k["key"], "deposit()", what=f"wrap ZEN bond {name}", to=V2["zen"], value=BOND)
            bond = num(call("balanceOf(address)(uint256)", k["address"], to=V2["zen"]))
        send(k["key"], "approve(address,uint256)", HUB, bond, what=f"approve bond {name}", to=V2["zen"])
        send(k["key"], "register(string,uint8,uint64,uint64,uint256)", name, cfg["mask"], cfg["cap_bps"],
                 cfg["max_dd_bps"], bond, what=f"register {name}")
        sid = num(call("strategyCount()(uint256)")) - 1
        send(k["key"], "mint(address,uint256)", k["address"], 5 * SEED, what=f"faucet tUSDC {name}", to=V2["usdc"])
        send(k["key"], "approve(address,uint256)", HUB, 2**256 - 1, what=f"approve tUSDC {name}", to=V2["usdc"])
        save(name, {"id": sid, "book": [0, 0, 0, 0], "salt": 0, "commit": 0, "started": False, "pending": None})
        print(f"{name}: vault {sid}, strategist {k['address']}, bond {bond / 1e18} WZEN", flush=True)


# ------------------------------------------------------------------ epochs

def liquidate_pro_rata(book, fraction_bps):
    """Sell the same fraction of every position, so redemptions are paid in cash
    without moving the book's weights. A small margin covers the price move to
    the close."""
    f = min(10_000, fraction_bps + 100)
    return [{"asset": a, "side": 1, "qty": book[a] * f // 10_000} for a in (1, 2, 3) if book[a] * f // 10_000 > 0]


def attest(oracle, e, books):
    _, _, net_buy, net_sell, crossed, proof = prover.net(epoch=e, books=books, tag=f"v2net_{e}")
    arr = lambda v: "[" + ",".join(map(str, v)) + "]"
    tx = send(oracle, "attest(uint64,uint64[4],uint64[4],uint64[4],bytes)", e, arr(net_buy), arr(net_sell),
                  arr(crossed), "0x" + proof.hex(), what=f"v2 netting proof e{e}", to=V2["attestor"])
    return net_buy, net_sell, crossed, tx


def epochs(n):
    prover.check_toolchain()
    oracle = oracle_key()
    hist_file = STATE / "v2-prices.json"
    if not hist_file.exists():
        v1 = STATE / "prices.json"
        hist_file.write_text(v1.read_text() if v1.exists() else json.dumps([spot_prices()]))
    history = json.loads(hist_file.read_text())
    length = V2["epoch_length"]

    for _ in range(n):
        e = num(call("currentEpoch()(uint64)"))
        closes = num(call("closesAt(uint64)(uint64)", e))
        if closes - time.time() < min(60, length // 3):
            time.sleep(max(0, closes - time.time()) + 2)
            e += 1
            closes += length

        # 1. seed, then commit before the close
        for name, cfg in VAULTS.items():
            st, k = load(name), key(name)
            ch = chain_strategy(st["id"])
            if ch["frozen"]:
                continue
            if not st["started"] and num(call("depositsIn(uint256,uint64)(uint64)", st["id"], e)) == 0:
                send(k["key"], "deposit(uint256,uint64)", st["id"], SEED, what=f"seed {name} e{e}")
            redeem = num(call("redeemsIn(uint256,uint64)(uint64)", st["id"], e))
            book = st["book"]
            if redeem and ch["total_shares"]:
                orders = liquidate_pro_rata(book, redeem * 10_000 // ch["total_shares"])
            elif name == "ai-agent":
                orders = cfg["fn"](book, history, cfg["cap_bps"], epoch=e)
            else:
                orders = cfg["fn"](book, history, cfg["cap_bps"])
            salt = prover.rand_salt()
            oc = prover.order_commit(st["id"], e, orders, salt)
            send(k["key"], "commitOrders(uint256,uint64,bytes32)", st["id"], e, "0x%064x" % oc, what=f"{name} commit e{e}")
            st["pending"] = {"epoch": e, "orders": orders, "salt": salt, "commit": oc}
            save(name, st)
            print(f"e{e} {name}: committed {len(orders)} order(s)" + (f", redemptions due {redeem / SCALE:,.2f} shares" if redeem else ""), flush=True)

        # 2. prices after the close
        time.sleep(max(0, closes - time.time()) + 3)
        px = spot_prices()
        if time.time() - closes > 120:
            print(f"e{e} skipped: prices ready {time.time() - closes:.0f} s after the close", flush=True)
            continue
        send(oracle, "postPrices(uint64,uint64[4])", e, "[" + ",".join(map(str, px)) + "]", what=f"v2 prices e{e}")
        history.append(px)
        hist_file.write_text(json.dumps(history[-500:]))

        # 2b. prove the batch's net flow
        live = [nm for nm in VAULTS if (load(nm).get("pending") or {}).get("epoch") == e]
        books = {load(nm)["id"]: (load(nm)["pending"]["orders"], load(nm)["pending"]["salt"], load(nm)["pending"]["commit"]) for nm in live}
        line = {"epoch": e, "prices": px}
        try:
            to_market, crossed = netting.net({nm: load(nm)["pending"]["orders"] for nm in live}, px)
            line.update(crossed=crossed, to_market=to_market)
            *_, line["attest_tx"] = attest(oracle, e, books)
            print(f"e{e} {netting.describe(to_market, crossed)}, proven on chain", flush=True)
        except Exception as x:
            print(f"e{e} netting proof failed: {str(x)[-200:]}", flush=True)
        with NET_LOG.open("a") as f:
            f.write(json.dumps(line) + "\n")

        # 3. settle each vault, its flows included
        for name in live:
            st, k = load(name), key(name)
            sid, p = st["id"], st["pending"]
            ch = chain_strategy(sid)
            inflow = num(call("depositsIn(uint256,uint64)(uint64)", sid, e))
            redeem = num(call("redeemsIn(uint256,uint64)(uint64)", sid, e))
            new_salt = prover.rand_salt()
            try:
                nc, nav, outflow, proof = prover.settle_vault(
                    strategy_id=sid, epoch=e, old_bal=st["book"], old_salt=st["salt"], orders=p["orders"],
                    orders_salt=p["salt"], new_salt=new_salt, old_commit=st["commit"] if st["started"] else 0,
                    orders_commit=p["commit"], prices=px, allowed_mask=VAULTS[name]["mask"],
                    max_weight_bps=VAULTS[name]["cap_bps"], inflow=inflow, redeem_shares=redeem,
                    total_shares=ch["total_shares"], tag=f"v2_{name}_{e}")
            except Exception as x:
                print(f"e{e} {name}: cannot prove ({str(x)[-160:]}), epoch left unsettled", flush=True)
                continue
            send(k["key"], "settle(uint256,uint64,bytes32,uint64,uint64,bytes)", sid, e, "0x%064x" % nc, nav,
                     outflow, "0x" + proof.hex(), what=f"{name} settle e{e}")
            st.update(book=prover.apply_flows(prover.apply_orders(st["book"], p["orders"], px), outflow, inflow),
                      salt=new_salt, commit=nc, started=True, pending=None)
            save(name, st)
            if num(call("depositOf(uint256,uint64,address)(uint64)", sid, e, k["address"])):
                send(k["key"], "claim(uint256,uint64)", sid, e, what=f"{name} claim e{e}")
            after = chain_strategy(sid)
            flows = (f", deposits {inflow / SCALE:,.2f}" if inflow else "") + (f", paid out {outflow / SCALE:,.2f}" if outflow else "")
            print(f"e{e} {name}: proof verified on chain, NAV {after['nav'] / SCALE:,.2f} tUSDC, share {after['share_price'] / SCALE:.6f}{flows}", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "setup":
        setup()
    elif sys.argv[1] == "epochs":
        epochs(int(sys.argv[2]))
