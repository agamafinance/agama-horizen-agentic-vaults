"""Check that the contracts on Horizen testnet are exactly the ones this repo
compiles. Immutables are written into runtime code at deployment, so they are
read back from the chain, checked against what the source says they must be,
and patched in before a byte-for-byte comparison.

  cd contracts && forge build && cd .. && python3 deployment/verify-bytecode.py
"""

import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEP = json.loads((ROOT / "deployment" / "testnet.json").read_text())

# what the immutables must hold, from the source and the deployment record
EXPECTED = {
    "EpochVerifier": {"n": 32768, "logN": 15, "numPublicInputs": 30},
    "AgentVaultHub": {"verifier": int(DEP["verifier"], 16), "oracle": int(DEP["oracle"], 16),
                      "genesisTime": DEP["genesis"], "epochLength": DEP["epoch_length"],
                      "sandboxCapital": DEP["capital"]},
}


def onchain(addr):
    return bytes.fromhex(subprocess.run(["cast", "code", addr, "--rpc-url", DEP["rpc"]],
                                        capture_output=True, text=True, check=True).stdout.strip()[2:])


def check(name, file, addr):
    art = json.loads((ROOT / "contracts" / "out" / file / f"{name}.json").read_text())
    local = bytearray(bytes.fromhex(art["deployedBytecode"]["object"][2:]))
    refs = art["deployedBytecode"]["immutableReferences"]
    chain = onchain(addr)
    seen = set()
    for spans in refs.values():
        vals = set()
        for s in spans:
            word = chain[s["start"]:s["start"] + s["length"]]
            vals.add(int.from_bytes(word, "big"))
            local[s["start"]:s["start"] + s["length"]] = word
        assert len(vals) == 1, "one immutable read back with two values"
        seen |= vals
    ok_values = seen == set(EXPECTED[name].values())
    ok_code = bytes(local) == chain
    print(f"{name} at {addr}: {len(chain)} bytes, code identical: {ok_code}, immutables as expected: {ok_values}")
    for k, v in EXPECTED[name].items():
        shown = "0x%040x" % v if k in ("verifier", "oracle") else v
        print(f"    {k} = {shown}{'' if v in seen else '  (NOT FOUND ON CHAIN)'}")
    return ok_code and ok_values


if __name__ == "__main__":
    a = check("EpochVerifier", "EpochVerifier.sol", DEP["verifier"])
    b = check("AgentVaultHub", "AgentVaultHub.sol", DEP["hub"])
    raise SystemExit(0 if a and b else 1)
