"""Print the README's results and attacks sections from chain data only.

  python3 deployment/report.py

Every figure comes from EpochSettled events and view calls on the hub, and
every attack from deployment/attacks.json, whose transactions anyone can open.
"""

import json
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEP = json.loads((HERE / "testnet.json").read_text())
RPC, HUB, EXP = DEP["rpc"], DEP["hub"], DEP["explorer"]
CAP = DEP["capital"] / 1e6


def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout.strip()


def settled():
    raw = json.loads(sh("cast", "logs", "--address", HUB, "--from-block", "29190254", "--json", "--rpc-url", RPC,
                        "EpochSettled(uint256 indexed,uint64 indexed,bytes32,uint64,uint64)"))
    out = []
    for log in raw:
        data = log["data"][2:]
        out.append({"id": int(log["topics"][1], 16), "epoch": int(log["topics"][2], 16),
                    "nav": int(data[64:128], 16) / 1e6, "tx": log["transactionHash"]})
    return out


def main():
    ev = settled()
    names = {}
    for i in range(int(sh("cast", "call", HUB, "strategyCount()(uint256)", "--rpc-url", RPC).split()[0])):
        t = sh("cast", "call", HUB, "strategy(uint256)((address,uint8,uint64,bytes32,uint64,bool,uint64,uint64,uint64,uint32,string))",
               str(i), "--rpc-url", RPC)
        names[i] = {"name": t.rsplit(",", 1)[1].strip(' )"'), "mdd": int(t.split(",")[8].split()[0]) / 100}

    print("### Track record so far\n")
    print(f"{len(ev)} settlements verified on chain. Sandbox capital {CAP:,.0f} USDC per strategy.\n")
    print("| Strategy | Epochs proven | Proven NAV (USDC) | Return | Max drawdown | Last proof |")
    print("|---|---|---|---|---|---|")
    for sid, meta in names.items():
        mine = [e for e in ev if e["id"] == sid]
        if not mine or meta["name"] == "attacker":
            continue
        last = mine[-1]
        print(f"| {meta['name']} | {len(mine)} | {last['nav']:,.2f} | {(last['nav'] - CAP) / CAP * 100:+.3f}% "
              f"| {meta['mdd']:.2f}% | [tx]({EXP}/tx/{last['tx']}) |")
    print("\nThe balances behind those numbers, and the orders that moved them, are not on chain.")

    atk = json.loads((HERE / "attacks.json").read_text())
    print("\n---\n")
    print("| Attack | What was sent | Refused by | Mined tx | Then, honestly |")
    print("|---|---|---|---|---|")
    what = {"late orders": "orders committed for an epoch that had closed",
            "inflated NAV": "a valid proof, with 100,000 USDC added to the NAV beside it",
            "swapped orders": "one order set committed, a larger one proven"}
    for a in atk["attacks"]:
        after = a.get("honest_settlement_same_proof") or a.get("honest_settlement_committed_orders")
        follow = f"[settled]({EXP}/tx/{after['tx']})" if after else "n/a"
        refused = a["refused_by_decoded"].split("(")[0]
        print(f"| {a['attack']} | {what[a['attack']]} | `{refused}` | [tx]({EXP}/tx/{a['tx']}) | {follow} |")


if __name__ == "__main__":
    main()
