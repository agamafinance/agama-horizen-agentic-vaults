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
(FIX / "proof_e5.bin").write_bytes(pr5)
(FIX / "proof_e6.bin").write_bytes(pr6)
h = lambda x: "0x%064x" % x
json.dump({"oc5": h(oc5), "nc5": h(nc5), "nav5": nav5, "prices5": e5,
           "oc6": h(oc6), "nc6": h(nc6), "nav6": nav6, "prices6": e6,
           "capital": CAP, "mask": MASK, "maxw": MAXW}, open(FIX / "epochs.json", "w"), indent=1)
print("nav5", nav5, "nav6", nav6)
