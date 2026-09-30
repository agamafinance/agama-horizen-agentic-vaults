#!/usr/bin/env bash
# Rebuild every circuit artefact the contracts depend on, from source.
#
#   ./zk/prove.sh
#
# Compiles and tests the circuits, regenerates EpochVerifier.sol and the two
# proofs the Foundry tests replay. Run it on a clean checkout and `git status`
# stays clean: the committed verifier and fixtures are exactly what the source
# produces, byte for byte.
set -euo pipefail
cd "$(dirname "$0")"
export PATH="$HOME/.nargo/bin:$HOME/.bb:$PATH"
echo "nargo $(nargo --version | head -1 | awk '{print $4}'), bb $(bb --version)"

echo "== circuits"
( cd order_commit && nargo compile )
( cd strategy_epoch && nargo compile && nargo test 2>&1 | tail -1 )

echo "== Solidity verifier"
( cd strategy_epoch
  bb write_vk --scheme ultra_honk --oracle_hash keccak -b target/strategy_epoch.json -o target/vk_dir >/dev/null
  bb write_solidity_verifier --scheme ultra_honk -k target/vk_dir/vk -o ../../contracts/src/EpochVerifier.sol >/dev/null )
sed -i.bak 's/^contract HonkVerifier is/contract EpochVerifier is/' ../contracts/src/EpochVerifier.sol
rm -f ../contracts/src/EpochVerifier.sol.bak

echo "== test fixtures"
python3 fixtures.py
