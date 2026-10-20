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

# ---- v2 vault, strategy 0 of a fresh VaultHub: a first deposit at epoch 5,
# a trade at 6, then at 7 ETH is up and a quarter of the shares is redeemed
VMASK, VMAXW = 0b1110, 5_000
v5 = [1_000_000, 2_500_000_000, 60_000_000_000, 8_000_000]
v6 = [1_000_000, 2_600_000_000, 61_000_000_000, 8_100_000]
v7 = [1_000_000, 3_000_000_000, 62_000_000_000, 8_200_000]
DEP = 10_000_000_000  # 10,000 tUSDC
vo6 = [{"asset": 1, "side": 0, "qty": 1_000_000}]
voc5 = p.order_commit(0, 5, [], 31)
vc5, vnav5, vout5, vp5 = p.settle_vault(strategy_id=0, epoch=5, old_bal=[0, 0, 0, 0], old_salt=0, orders=[],
    orders_salt=31, new_salt=41, old_commit=0, orders_commit=voc5, prices=v5, allowed_mask=VMASK,
    max_weight_bps=VMAXW, inflow=DEP, redeem_shares=0, total_shares=0, tag="v5")
vb5 = p.apply_flows([0, 0, 0, 0], vout5, DEP)
voc6 = p.order_commit(0, 6, vo6, 32)
vc6, vnav6, vout6, vp6 = p.settle_vault(strategy_id=0, epoch=6, old_bal=vb5, old_salt=41, orders=vo6,
    orders_salt=32, new_salt=42, old_commit=vc5, orders_commit=voc6, prices=v6, allowed_mask=VMASK,
    max_weight_bps=VMAXW, inflow=0, redeem_shares=0, total_shares=DEP, tag="v6")
vb6 = p.apply_flows(p.apply_orders(vb5, vo6, v6), vout6, 0)
voc7 = p.order_commit(0, 7, [], 33)
vc7, vnav7, vout7, vp7 = p.settle_vault(strategy_id=0, epoch=7, old_bal=vb6, old_salt=42, orders=[],
    orders_salt=33, new_salt=43, old_commit=vc6, orders_commit=voc7, prices=v7, allowed_mask=VMASK,
    max_weight_bps=VMAXW, inflow=0, redeem_shares=2_500_000_000, total_shares=DEP, tag="v7")
for n, pr in (("5", vp5), ("6", vp6), ("7", vp7)):
    (FIX / f"vault_e{n}.bin").write_bytes(pr)
json.dump({"deposit": DEP, "redeem": 2_500_000_000, "mask": VMASK, "maxw": VMAXW,
           "e5": {"oc": h(voc5), "book": h(vc5), "nav": vnav5, "outflow": vout5, "prices": v5},
           "e6": {"oc": h(voc6), "book": h(vc6), "nav": vnav6, "outflow": vout6, "prices": v6},
           "e7": {"oc": h(voc7), "book": h(vc7), "nav": vnav7, "outflow": vout7, "prices": v7}},
          open(FIX / "vault.json", "w"), indent=1)
print(f"vault e5 NAV {vnav5 / 1e6:,.2f} · e6 NAV {vnav6 / 1e6:,.2f} · e7 NAV {vnav7 / 1e6:,.2f}, paid out {vout7 / 1e6:,.2f} USDC")
