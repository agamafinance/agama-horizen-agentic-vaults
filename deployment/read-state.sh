#!/usr/bin/env bash
# Everything a depositor can see, read with eth_call only. No key, no trust in us.
#
#   ./deployment/read-state.sh
set -euo pipefail
cd "$(dirname "$0")"
RPC=$(python3 -c "import json;print(json.load(open('testnet.json'))['rpc'])")
HUB=$(python3 -c "import json;print(json.load(open('testnet.json'))['hub'])")
c() { cast call "$HUB" "$@" --rpc-url "$RPC" | awk '{print $1}'; }

echo "AgentVaultHub $HUB (Horizen testnet)"
echo "  epoch length $(c 'epochLength()(uint64)') s, current epoch $(c 'currentEpoch()(uint64)'), sandbox capital $(( $(c 'sandboxCapital()(uint64)') / 1000000 )) USDC"
N=$(c 'strategyCount()(uint256)')
echo "  strategies: $N"
for ((i = 0; i < N; i++)); do
  cast call "$HUB" 'strategy(uint256)((address,uint8,uint64,bytes32,uint64,bool,uint64,uint64,uint64,uint32,string))' "$i" --rpc-url "$RPC" \
  | python3 -c "
import sys, re
t = sys.stdin.read().strip()[1:-1]
f = [x.strip() for x in re.split(r',(?![^\[]*\])', t)]
owner, mask, cap, book, last, started, nav, peak, mdd, n, name = f
nav = int(nav.split()[0]); peak = int(peak.split()[0])
assets = [a for a, b in zip(['ETH','BTC','ZEN'], [2,4,8]) if int(mask) & b]
print(f'  [{$i}] {name.strip(chr(34))}: ' + (f'{n} epochs proven, NAV {nav/1e6:,.2f} USDC, return {(nav-1e12)/1e10:+.2f}%, max drawdown {int(mdd.split()[0])/100:.2f}%' if started == 'true' else 'not started'))
print(f'      mandate: {\"/\".join(assets)}, max {int(cap.split()[0])/100:.0f}% per asset | book commitment {book[:18]}... | balances: private')
"
done

ATT=$(python3 -c "import json;print(json.load(open('testnet.json'))['attestor'])")
a() { cast call "$ATT" "$@" --rpc-url "$RPC" | awk '{print $1}'; }
LAST=$(a 'lastEpoch()(uint64)')
echo
echo "NettingAttestor $ATT"
echo "  epochs with a proven net flow: $(a 'epochsProven()(uint256)'), last one $LAST"
cast call "$ATT" 'flow(uint64)((uint64[4],uint64[4],uint64[4],uint8,bool))' "$LAST" --rpc-url "$RPC" | python3 -c "
import sys, re
t = re.sub(r'\[[0-9.]+e[0-9]+\]', '', sys.stdin.read())  # drop cast's scientific annotations
nums = [int(x) for x in re.findall(r'\d+', t.split('[', 1)[1])]
buy, sell, crossed, n = nums[0:4], nums[4:8], nums[8:12], nums[12]
names = ['USDC', 'ETH', 'BTC', 'ZEN']
side = lambda a: f'buy {buy[a]/1e6:,.6f}' if buy[a] else (f'sell {sell[a]/1e6:,.6f}' if sell[a] else 'nothing')
print(f'  epoch $LAST, {n} strategies netted, orders: private')
for a in (1, 2, 3):
    print(f'      {names[a]}: to market {side(a)}, crossed inside the batch {crossed[a]/1e6:,.6f}')
"

# ---- v2: vaults with depositors
VH=$(python3 -c "import json;print(json.load(open('testnet-v2.json'))['vault_hub'])")
v() { cast call "$VH" "$@" --rpc-url "$RPC" | awk '{print $1}'; }
echo
echo "VaultHub $VH (vaults with depositors)"
echo "  current epoch $(v 'currentEpoch()(uint64)'), outside deposits open after $(v 'SANDBOX_EPOCHS()(uint64)') proven epochs"
VN=$(v 'strategyCount()(uint256)')
for ((i = 0; i < VN; i++)); do
  CAP=$(v 'capacity(uint256)(uint64)' "$i")
  cast call "$VH" 'strategy(uint256)((address,uint8,uint64,uint64,bytes32,uint64,bool,bool,uint64,uint64,uint64,uint64,uint64,uint64,uint32,uint256,string))' "$i" --rpc-url "$RPC" \
  | python3 -c "
import sys, re
t = re.sub(r'\[[0-9.]+e[0-9]+\]', '', sys.stdin.read().strip()[1:-1])
f = [x.strip() for x in t.split(', ')]
owner, mask, cap, dd_lim, book, last, started, frozen, nav, shares, price, hwm, peak, dd, n, bond = f[:16]
name = ', '.join(f[16:]).strip(chr(34))
assets = [a for a, b in zip(['ETH','BTC','ZEN'], [2,4,8]) if int(mask) & b]
state = 'frozen' if frozen == 'true' else ('open' if int(n) >= 20 else f'sandbox {n}/20')
print(f'  [{$i}] {name} ({state}): share price {int(price)/1e6:.6f} tUSDC, return {(int(price)/1e6-1)*100:+.3f}%, max drawdown {int(dd)/100:.2f}%, {n} epochs proven')
print(f'      {int(nav)/1e6:,.2f} tUSDC managed of {$CAP/1e6:,.0f} its bond of {int(bond)/1e18} ZEN allows | mandate {\"/\".join(assets)}, max {int(cap)/100:.0f}% each | holdings: private')
"
done
