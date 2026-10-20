"""An AI agent as a strategy.

The agent is a language model asked, every DECIDE_EVERY epochs, for target
weights. Between decisions it holds. Its prompt is its edge: the harness reads
it from agents/.private/agent-prompt.md, which never leaves the strategist's
machine (git ignores it); this repository only carries an example. On chain the
agent is a strategy like any other: committed orders, a proven book, a proven
NAV. Nobody can read its prompt, its holdings or its trades, and nobody has to
trust its claims about performance.

The model runs through the Claude Code CLI in headless mode. Any model works:
the harness only needs JSON weights back.
"""

import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PROMPT = ROOT / ".private" / "agent-prompt.md"
EXAMPLE = ROOT / "agent-prompt.example.md"
JOURNAL = ROOT / "state" / "agent-journal.jsonl"  # private: the agent's decisions stay local
CLAUDE = str(Path.home() / ".local" / "bin" / "claude")
DECIDE_EVERY = 10  # epochs: one decision every half hour
SCALE = 1_000_000
NAMES = {1: "ETH", 2: "BTC", 3: "ZEN"}


def _value(qty, price):
    return qty * price // SCALE


def ask(context: dict) -> dict:
    prompt = (PROMPT if PROMPT.exists() else EXAMPLE).read_text()
    r = subprocess.run(
        [CLAUDE, "-p", prompt + "\n\nVault state:\n" + json.dumps(context), "--model", "sonnet", "--output-format", "json"],
        capture_output=True, text=True, timeout=240, cwd="/tmp",
    )
    out = json.loads(r.stdout)
    text = out["result"].strip()
    weights = json.loads(text[text.index("{"):text.rindex("}") + 1])["weights"]
    return {k: float(v) for k, v in weights.items()}


def make(mask: int, cap_bps: int):
    allowed = [a for a in (1, 2, 3) if mask >> a & 1]
    state = {"last": None, "weights": {}}
    if JOURNAL.exists() and JOURNAL.read_text().strip():  # a restart keeps the last decision
        last = json.loads(JOURNAL.read_text().strip().splitlines()[-1])
        state.update(last=last["epoch"], weights=last["weights"])

    def agent(book, history, _cap_bps, epoch=None):
        now = history[-1]
        nav = sum(_value(book[i], now[i]) for i in range(4))
        if nav == 0:
            return []
        if state["last"] is None or epoch is None or epoch - state["last"] >= DECIDE_EVERY:
            window = history[-40:]
            context = {
                "nav_usdc": nav / SCALE,
                "holdings": {"USDC": book[0] / SCALE, **{NAMES[a]: book[a] / SCALE for a in allowed}},
                "mandate": {"assets": [NAMES[a] for a in allowed], "max_weight_per_asset": cap_bps / 10_000 - 0.05},
                "closes_every_3_minutes": {NAMES[a]: [p[a] / SCALE for p in window] for a in allowed},
            }
            try:
                w = ask(context)
                state["weights"] = w
                state["last"] = epoch
                with JOURNAL.open("a") as f:
                    f.write(json.dumps({"epoch": epoch, "at": time.time(), "weights": w}) + "\n")
            except Exception as x:  # no answer, no trade
                print(f"agent: no decision ({str(x)[:120]}), holding", flush=True)
                return []
        return rebalance(book, now, state["weights"], allowed, cap_bps)

    return agent


def rebalance(book, prices, weights, allowed, cap_bps):
    """Orders that move the book toward the target weights. Sells first so their
    cash funds the buys; buys keep a margin because they fill at the next close,
    not at the price seen now."""
    nav = sum(_value(book[i], prices[i]) for i in range(4))
    cap = (cap_bps - 500) / 10_000
    target = {a: max(0.0, min(cap, float(weights.get(NAMES[a], 0)))) for a in allowed}
    total = sum(target.values())
    if total > 0.9:
        target = {a: w * 0.9 / total for a, w in target.items()}
    sells, buys = [], []
    cash = book[0]
    for a in allowed:
        want = int(nav * target[a])
        have = _value(book[a], prices[a])
        delta = want - have
        if abs(delta) < nav // 100:  # under 1% of the book: not worth a trade
            continue
        if delta < 0:
            qty = min(book[a], -delta * SCALE // prices[a])
            if qty:
                sells.append({"asset": a, "side": 1, "qty": qty})
                cash += _value(qty, prices[a])
    for a in allowed:
        want = int(nav * target[a])
        have = _value(book[a], prices[a])
        delta = want - have
        if delta >= nav // 100:
            spend = min(delta, cash * 93 // 100)
            qty = spend * SCALE // prices[a]
            if qty:
                buys.append({"asset": a, "side": 0, "qty": qty})
                cash -= _value(qty, prices[a])
    return sells + buys
