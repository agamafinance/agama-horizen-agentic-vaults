"""Two small strategies for the sandbox.

They are deliberately simple. The point of the demo is not their edge, it is
that whatever they do stays off chain while their results are proven on it.
Each one sees only its own book and the public price history, and returns up
to four orders for the next epoch.

Units match the circuit: quantities in millionths of an asset, prices in
millionths of a USDC per whole unit. Asset 0 is USDC, 1 ETH, 2 BTC, 3 ZEN.
"""

SCALE = 1_000_000


def _value(qty, price):
    return qty * price // SCALE


def _nav(book, prices):
    return sum(_value(book[i], prices[i]) for i in range(4))


def _buy(asset, cash, price):
    qty = cash * SCALE // price
    return {"asset": asset, "side": 0, "qty": qty} if qty > 0 else None


def _sell(asset, qty):
    return {"asset": asset, "side": 1, "qty": qty} if qty > 0 else None


def _room(book, prices, asset, cap_bps, nav):
    """Cash that can go into `asset` without breaching the weight cap or running
    out of cash, with margins because orders are set before the closing price
    they fill at is known."""
    limit = nav * (cap_bps - 500) // 10_000
    return max(0, min(book[0] * 9 // 10, limit - _value(book[asset], prices[asset])))


def momentum(book, history, cap_bps):
    """Trend follower on ETH and BTC: add to what went up, cut what went down."""
    now, prev = history[-1], history[-2] if len(history) > 1 else history[-1]
    book = list(book)
    nav = _nav(book, now)
    orders = []
    for a in (1, 2):
        if now[a] > prev[a]:
            o = _buy(a, min(nav // 10, _room(book, now, a, cap_bps, nav)), now[a])
        elif now[a] < prev[a]:
            o = _sell(a, book[a] // 2)
        else:
            o = None
        if o:
            orders.append(o)
            if o["side"] == 0:
                book[0] -= _value(o["qty"], now[a])  # the next buy sees less cash
    return orders


def mean_reversion(book, history, cap_bps):
    """Fades moves on ETH and ZEN against a short average."""
    now = history[-1]
    window = history[-4:]
    book = list(book)
    nav = _nav(book, now)
    orders = []
    for a in (1, 3):
        avg = sum(p[a] for p in window) // len(window)
        if now[a] < avg:
            o = _buy(a, min(nav // 8, _room(book, now, a, cap_bps, nav)), now[a])
        elif now[a] > avg:
            o = _sell(a, book[a] // 3)
        else:
            o = None
        if o:
            orders.append(o)
            if o["side"] == 0:
                book[0] -= _value(o["qty"], now[a])  # the next buy sees less cash
    return orders


STRATEGIES = {
    "momentum": {"fn": momentum, "mask": 0b0110, "cap_bps": 4_000},
    "mean-reversion": {"fn": mean_reversion, "mask": 0b1010, "cap_bps": 4_000},
}
