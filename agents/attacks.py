"""Attack the live hub, on chain, with real transactions that get mined and
revert. Runs as its own strategy so it never touches the honest ones, and each
attack is set up so that every check before the targeted one passes: a refusal
is only reported when the mechanism under test is the one that refused.

  python3 agents/attacks.py      (while agents/run.py is posting prices)

  1. late orders    commit for an epoch that has already closed
  2. inflated NAV   a valid proof, with a better NAV typed next to it
  3. swapped orders commit one order set, prove another

After attacks 2 and 3 the honest settlement goes through with the same proof
or the same commitment, which shows the attack was the only thing wrong.
Results go to deployment/attacks.json.
"""

import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "zk"))
import prover  # noqa: E402

DEP = json.loads((ROOT / "deployment" / "testnet.json").read_text())
RPC, HUB, CAP = DEP["rpc"], DEP["hub"], DEP["capital"]
KEYS = ROOT / "agents" / ".keys"
OUT = ROOT / "deployment" / "attacks.json"
MASK, CAPBPS = 0b0110, 4_000


def sh(*a):
    r = subprocess.run(a, capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip()[-300:])
    return r.stdout.strip()


def call(sig, *a):
    return sh("cast", "call", HUB, sig, *map(str, a), "--rpc-url", RPC).split()[0]


def send(key, sig, *a, force=False):
    extra = ["--gas-limit", "4000000"] if force else []  # skip estimation so a revert is mined
    tx = json.loads(sh("cast", "send", HUB, sig, *map(str, a), *extra, "--private-key", key, "--rpc-url", RPC, "--json"))
    return tx["transactionHash"], tx["status"] == "0x1", int(tx["blockNumber"], 16)


def reason(key_addr, sig, block, *a):
    """Replay the call at the block before, to read which check refused."""
    r = subprocess.run(["cast", "call", HUB, sig, *map(str, a), "--from", key_addr, "--block", str(block - 1),
                        "--rpc-url", RPC], capture_output=True, text=True)
    txt = (r.stdout + r.stderr).strip()
    return txt.split("execution reverted")[-1].strip(" ,:")[:160] if r.returncode else "did not revert"


def wait_prices(epoch):
    while call("pricesPosted(uint64)(bool)", epoch) != "true":
        time.sleep(5)
    return [int(x) for x in sh("cast", "call", HUB, "pricesAt(uint64)(uint64[4])", str(epoch), "--rpc-url", RPC)
            .strip("[]").replace(" ", "").split(",")]


def next_open_epoch():
    e = int(call("currentEpoch()(uint64)"))
    if int(call("closesAt(uint64)(uint64)", e)) - time.time() < 50:
        time.sleep(int(call("closesAt(uint64)(uint64)", e)) - time.time() + 2)
        e += 1
    return e


def main():
    KEYS.mkdir(exist_ok=True)
    kf = KEYS / "attacker.json"
    if not kf.exists():
        w = json.loads(sh("cast", "wallet", "new", "--json"))[0]
        kf.write_text(json.dumps({"address": w["address"], "key": w["private_key"]}))
    k = json.loads(kf.read_text())
    funder = sh("bash", "-c", f"source {ROOT.parent / 'agama-horizen' / '.env.local'} && echo $DEPLOYER_PK")
    if int(sh("cast", "balance", k["address"], "--rpc-url", RPC)) < 200_000_000_000_000:
        sh("cast", "send", k["address"], "--value", "0.0004ether", "--private-key", funder, "--rpc-url", RPC)
    send(k["key"], "register(string,uint8,uint64)", "attacker", MASK, CAPBPS)
    sid = int(call("strategyCount()(uint256)")) - 1
    results = {"strategy": sid, "attacker": k["address"], "hub": HUB, "attacks": []}

    def record(name, target, sig, args, txh, ok, blk):
        results["attacks"].append({"attack": name, "targeted_check": target, "tx": txh, "mined": True,
                                   "reverted": not ok, "refused_by": reason(k["address"], sig, blk, *args)})
        print(f"{name}: tx {txh} reverted={not ok}")

    # ---- epoch A: late orders, then inflated NAV on the genesis settlement
    e = next_open_epoch()
    orders_a = [{"asset": 1, "side": 0, "qty": 20_000_000}]  # buy 20 ETH
    salt_a = prover.rand_salt()
    oc_a = prover.order_commit(sid, e, orders_a, salt_a)
    send(k["key"], "commitOrders(uint256,uint64,bytes32)", sid, e, "0x%064x" % oc_a)

    sig = "commitOrders(uint256,uint64,bytes32)"
    args = (sid, e - 1, "0x%064x" % oc_a)
    txh, ok, blk = send(k["key"], sig, *args, force=True)
    record("late orders", "EpochClosed", sig, args, txh, ok, blk)

    px = wait_prices(e)
    book_salt = prover.rand_salt()
    nc, nav, proof, _ = prover.settle(strategy_id=sid, epoch=e, old_bal=[CAP, 0, 0, 0], old_salt=0, orders=orders_a,
        orders_salt=salt_a, new_salt=book_salt, old_commit=0, orders_commit=oc_a, prices=px, allowed_mask=MASK,
        max_weight_bps=CAPBPS, is_genesis=True, genesis_capital=CAP, tag=f"atk_{e}")
    sig = "settle(uint256,uint64,bytes32,uint64,bytes)"
    args = (sid, e, "0x%064x" % nc, nav + 100_000_000_000, "0x" + proof.hex())  # +100,000 USDC
    txh, ok, blk = send(k["key"], sig, *args, force=True)
    record("inflated NAV", "verifier (NAV is a proof output)", sig, args, txh, ok, blk)
    txh, ok, _ = send(k["key"], sig, sid, e, "0x%064x" % nc, nav, "0x" + proof.hex())
    results["attacks"][-1]["honest_settlement_same_proof"] = {"tx": txh, "ok": ok, "nav": nav}
    book = prover.apply_orders([CAP, 0, 0, 0], orders_a, px)

    # ---- epoch B: commit one order set, prove another
    e2 = next_open_epoch()
    committed = [{"asset": 1, "side": 1, "qty": 5_000_000}]  # sell 5 ETH
    proved = [{"asset": 1, "side": 1, "qty": 15_000_000}]  # the one it would rather have done
    s_c, s_p = prover.rand_salt(), prover.rand_salt()
    oc_c = prover.order_commit(sid, e2, committed, s_c)
    oc_p = prover.order_commit(sid, e2, proved, s_p)
    send(k["key"], "commitOrders(uint256,uint64,bytes32)", sid, e2, "0x%064x" % oc_c)
    px2 = wait_prices(e2)
    new_salt = prover.rand_salt()
    nc_p, nav_p, proof_p, _ = prover.settle(strategy_id=sid, epoch=e2, old_bal=book, old_salt=book_salt, orders=proved,
        orders_salt=s_p, new_salt=new_salt, old_commit=nc, orders_commit=oc_p, prices=px2, allowed_mask=MASK,
        max_weight_bps=CAPBPS, is_genesis=False, genesis_capital=CAP, tag=f"atk_{e2}_p")
    args = (sid, e2, "0x%064x" % nc_p, nav_p, "0x" + proof_p.hex())
    txh, ok, blk = send(k["key"], sig, *args, force=True)
    record("swapped orders", "verifier (orders commitment is a public input)", sig, args, txh, ok, blk)
    nc_c, nav_c, proof_c, _ = prover.settle(strategy_id=sid, epoch=e2, old_bal=book, old_salt=book_salt, orders=committed,
        orders_salt=s_c, new_salt=new_salt, old_commit=nc, orders_commit=oc_c, prices=px2, allowed_mask=MASK,
        max_weight_bps=CAPBPS, is_genesis=False, genesis_capital=CAP, tag=f"atk_{e2}_c")
    txh, ok, _ = send(k["key"], sig, sid, e2, "0x%064x" % nc_c, nav_c, "0x" + proof_c.hex())
    results["attacks"][-1]["honest_settlement_committed_orders"] = {"tx": txh, "ok": ok, "nav": nav_c}

    OUT.write_text(json.dumps(results, indent=1))
    print(json.dumps(results, indent=1))


if __name__ == "__main__":
    main()
