#!/usr/bin/env bash
# Replay the inflated-NAV attack against the live hub, read-only.
#
# Takes the two settlement transactions the attack script mined (the refused
# one, with 100,000 USDC added to the NAV, and the honest one that followed
# with the same proof) and re-executes both with eth_call at the block before
# the attack, from the attacker's address. Nothing is sent.
#
#   ./deployment/replay-attack.sh
set -euo pipefail
cd "$(dirname "$0")"
RPC=$(python3 -c "import json;print(json.load(open('testnet.json'))['rpc'])")
read -r ATTACKER BAD GOOD < <(python3 -c "
import json; a = json.load(open('attacks.json')); x = next(t for t in a['attacks'] if t['attack'] == 'inflated NAV')
print(a['attacker'], x['tx'], x['honest_settlement_same_proof']['tx'])")

replay() { # replay <label> <tx>
  local to input block nav
  to=$(cast tx "$2" to --rpc-url "$RPC"); input=$(cast tx "$2" input --rpc-url "$RPC")
  block=$(cast tx "$BAD" blockNumber --rpc-url "$RPC")
  nav=$(cast calldata-decode "settle(uint256,uint64,bytes32,uint64,bytes)" "$input" | sed -n 4p | awk '{print $1}')
  printf '%-14s NAV %s USDC  ->  ' "$1" "$(python3 -c "print(f'{$nav/1e6:,.2f}')")"
  if out=$(cast call "$to" "$input" --from "$ATTACKER" --block $((block - 1)) --rpc-url "$RPC" 2>&1); then
    echo "accepted"
  else
    sel=$(grep -oE '0x[0-9a-f]{8}' <<<"$out" | head -1)
    [ "$sel" = "0x9fc3a218" ] && echo "refused by the verifier: SumcheckFailed()" || echo "refused: $sel"
  fi
}
replay "inflated" "$BAD"
replay "true" "$GOOD"
