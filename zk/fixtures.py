"""Build the proofs the Foundry tests replay: strategy 0, genesis at epoch 5,
then a second epoch at 6 that opens the book epoch 5 produced."""

import json
from pathlib import Path
import prover as p

FIX = Path(__file__).resolve().parent.parent / "contracts" / "test" / "fixtures"
FIX.mkdir(parents=True, exist_ok=True)
CAP = 1_000_000_000_000  # 1,000,000 USDC of sandbox cash
MASK, MAXW = 0b1110, 5_000

e5 = [1_000_000, 2_500_000_000, 60_000_000_000, 8_000_000]
e6 = [1_000_000, 2_600_000_000, 59_000_000_000, 8_200_000]
o5 = [{"asset": 1, "side": 0, "qty": 100_000_000}, {"asset": 3, "side": 0, "qty": 5_000_000_000}]
o6 = [{"asset": 1, "side": 1, "qty": 40_000_000}]

out = {}
oc5 = p.order_commit(0, 5, o5, 11)
nc5, nav5, pr5, _ = p.settle(strategy_id=0, epoch=5, old_bal=[CAP, 0, 0, 0], old_salt=0, orders=o5,
    orders_salt=11, new_salt=21, old_commit=0, orders_commit=oc5, prices=e5, allowed_mask=MASK,
    max_weight_bps=MAXW, is_genesis=True, genesis_capital=CAP, tag="e5")
bal5 = p.apply_orders([CAP, 0, 0, 0], o5, e5)
oc6 = p.order_commit(0, 6, o6, 12)
nc6, nav6, pr6, _ = p.settle(strategy_id=0, epoch=6, old_bal=bal5, old_salt=21, orders=o6,
    orders_salt=12, new_salt=22, old_commit=nc5, orders_commit=oc6, prices=e6, allowed_mask=MASK,
    max_weight_bps=MAXW, is_genesis=False, genesis_capital=CAP, tag="e6")
# netting at epoch 5: strategy 0's orders above against strategy 1's, which sells
# 30 of the 100 ETH strategy 0 buys, and some BTC
o5b = [{"asset": 1, "side": 1, "qty": 30_000_000}, {"asset": 2, "side": 1, "qty": 500_000}]
oc5b = p.order_commit(1, 5, o5b, 13)
_, _, net_buy, net_sell, crossed, prn = p.net(epoch=5, books={0: (o5, 11, oc5), 1: (o5b, 13, oc5b)}, tag="n5")
(FIX / "net_e5.bin").write_bytes(prn)
json.dump({"oc5b": "0x%064x" % oc5b, "net_buy": net_buy, "net_sell": net_sell, "crossed": crossed},
          open(FIX / "netting.json", "w"), indent=1)
(FIX / "proof_e5.bin").write_bytes(pr5)
(FIX / "proof_e6.bin").write_bytes(pr6)
h = lambda x: "0x%064x" % x
json.dump({"oc5": h(oc5), "nc5": h(nc5), "nav5": nav5, "prices5": e5,
           "oc6": h(oc6), "nc6": h(nc6), "nav6": nav6, "prices6": e6,
           "capital": CAP, "mask": MASK, "maxw": MAXW}, open(FIX / "epochs.json", "w"), indent=1)
print(f"netting e5: buy {net_buy}, sell {net_sell}, crossed {crossed}")
print(f"epoch 5 proven: NAV {nav5 / 1e6:,.2f} USDC  ·  epoch 6 proven: NAV {nav6 / 1e6:,.2f} USDC  ·  proofs {len(pr5):,} B each")
