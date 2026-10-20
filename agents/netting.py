"""Netting across strategies, one batch per epoch.

Every strategy commits its orders before the close and fills at the closing
price, so opposite orders on the same asset can be crossed with each other at
that price, inside the batch. Only what is left over, one net order per asset,
goes to market. A venue, or anyone watching it, sees the net flow of the whole
hub for the epoch: not which strategy traded, not what each one did.

Units match the circuit: quantities in millionths of an asset, prices in
millionths of a USDC per whole unit. Side 0 buys, side 1 sells.
"""

SCALE = 1_000_000
ASSETS = ("USDC", "ETH", "BTC", "ZEN")


def net(orders_by_strategy, prices):
    """Cross the epoch's orders. Returns the net orders to send to market and
    what stayed inside the batch, both per asset."""
    bought = [0] * len(ASSETS)
    sold = [0] * len(ASSETS)
    for orders in orders_by_strategy.values():
        for o in orders:
            if o["qty"] <= 0 or o["asset"] == 0:
                continue
            (bought if o["side"] == 0 else sold)[o["asset"]] += o["qty"]

    to_market, crossed = [], []
    for a in range(1, len(ASSETS)):
        inside = min(bought[a], sold[a])
        if inside:
            crossed.append({"asset": a, "qty": inside, "usdc": inside * prices[a] // SCALE})
        rest = bought[a] - sold[a]
        if rest:
            to_market.append({"asset": a, "side": 0 if rest > 0 else 1, "qty": abs(rest),
                              "usdc": abs(rest) * prices[a] // SCALE})
    return to_market, crossed


def describe(to_market, crossed):
    """One line for the run log."""
    def fmt(o):
        return f"{'buy' if o.get('side', 0) == 0 else 'sell'} {o['qty'] / SCALE:,.6f} {ASSETS[o['asset']]}"
    inside = sum(c["usdc"] for c in crossed) / SCALE
    outside = sum(o["usdc"] for o in to_market) / SCALE
    net_part = ", ".join(fmt(o) for o in to_market) or "nothing"
    return f"netting: {inside:,.2f} USDC crossed inside the batch, to market: {net_part} ({outside:,.2f} USDC)"
