#!/usr/bin/env node
// Agama execution module for ZENDEX (Horizen testnet, chainId 2651420).
// Reproduces the client flow of the public ZENDEX app: deposit proof sent from
// our wallet, then inclusion + swap (or split) proofs sent through the ZENDEX
// relayer. `execute` turns the hub's net flow of each netting window into
// shielded swaps at sandbox scale.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ethers } from 'ethers';
import { Noir } from '@noir-lang/noir_js';
import { UltraHonkBackend } from '@aztec/bb.js';
import { poseidon1, poseidon2, poseidon3 } from 'poseidon-lite';
import { parseLog, selectWindow, aggregate, scaleLeg } from './aggregate.mjs';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(DIR, '../..');
const STATE = path.join(DIR, '.state');
const NETTING_LOG = process.env.NETTING_LOG || path.join(ROOT, 'deployment/netting-log.jsonl');
const EXECUTION_LOG = process.env.EXECUTION_LOG || path.join(ROOT, 'deployment/execution-log.jsonl');
const SCALE_DOWN = BigInt(process.env.SCALE_DOWN || 10000);
const FIRST_RUN_EPOCHS = Number(process.env.FIRST_RUN_EPOCHS || 20);
const MAX_RELAYS = Number(process.env.MAX_RELAYS || 6);
const MIN_LEG_USDC = BigInt(process.env.MIN_LEG_USDC || 500_000); // 0.5 tUSDC
const SLIPPAGE_BPS = BigInt(process.env.SLIPPAGE_BPS || 100); // minOut = quote - 1 %
const PENDING_TIMEOUT_MS = 15 * 60 * 1000;

const RPC = process.env.ZENDEX_RPC || 'https://horizen-testnet.rpc.caldera.xyz/http';
const CHAIN_ID = 2651420;
const VAULT_MANAGER = '0xCD2c51848ef806E3f23D7D0247400B305aDC6f3F';
const TREE = '0xd80D13aC7a5101Db58ec0B063a3794803B5e00ED';
const ROUTER = '0x1C07c6115ee2Ed9D7710a2e4CF1050FC0b39D128';
const RELAYER = 'https://lkezjmksbvt3v2fohitvs4rd5e0debuc.lambda-url.eu-central-1.on.aws';
const P = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;

// asset_id is the token's index in the app's token list
export const TOKENS = [
  { id: 0, label: 'WZEN', address: '0x0497118dFAC26D8d05eB32669ba5568c7395cf44', decimals: 18 },
  { id: 1, label: 'tUSDC', address: '0x276BF638000b0C80Ebd3d33104846E9F909C1f16', decimals: 6 },
  { id: 2, label: 'tcbBTC', address: '0x0A6810144F0cc1cBa9CcaCA194108bdD225eA047', decimals: 8 },
  { id: 3, label: 'tZKZ', address: '0xb512E511f92E0cdE0b4C1E2E302C11FDf93ba514', decimals: 18 },
];
const T = { WZEN: TOKENS[0], tUSDC: TOKENS[1], tcbBTC: TOKENS[2] };
const MINT_CAP = 1000n; // the app's faucet limit per mint, in whole tokens

const ERC20 = [
  'function mint(address to, uint256 amount)',
  'function approve(address spender, uint256 value) returns (bool)',
  'function allowance(address owner, address spender) view returns (uint256)',
  'function balanceOf(address) view returns (uint256)',
];
const VM_ABI = ['function deposit((bytes proof, bytes32[] publicInputs) data)'];
const TREE_ABI = [
  'event LeafInserted(uint256 indexed epoch, uint256 indexed leafIndex, uint256 indexed leaf, uint256 newRoot)',
  'function getHistoricalTree(uint256 epoch) view returns ((uint8 depth, uint256 root, uint256 leafCount, uint256 epochId))',
  'function getHistoricalProof(uint256 leaf, uint256 epoch) view returns ((uint256[] siblings, uint8[] indices))',
  'function commitments(uint256) view returns (bool exists)',
  'function nullifierUsed(uint256) view returns (bool used)',
];
const ROUTER_ABI = [
  'function getAmountsOut(uint256 amountIn, address[] path) view returns (uint256[] amounts)',
  'function getAmountsIn(uint256 amountOut, address[] path) view returns (uint256[] amounts)',
];

const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
const tree = new ethers.Contract(TREE, TREE_ABI, provider);
const router = new ethers.Contract(ROUTER, ROUTER_ABI, provider);

// ---------------- state ----------------
const f = (name) => path.join(STATE, name);
const readJson = (file, d) => (fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : d);
function writeJson(file, v) {
  fs.mkdirSync(STATE, { recursive: true, mode: 0o700 });
  const tmp = file + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(v, (_, x) => (typeof x === 'bigint' ? x.toString() : x), 2), { mode: 0o600 });
  fs.renameSync(tmp, file);
}
const loadDb = () => {
  const db = readJson(f('notes.json'), {});
  db.deposits ||= []; db.spent ||= []; db.pendingRelays ||= []; db.txs ||= []; db.exec ||= {};
  db.exec.dustIndex ??= 0;
  return db;
};
const saveDb = (db) => writeJson(f('notes.json'), db);
const nextRef = (db) => `d${db.deposits.length + db.spent.length + 1}`;
const logTx = (db, kind, hash, extra = {}) => db.txs.push({ kind, hash, at: new Date().toISOString(), ...extra });

function wallet() {
  const j = readJson(f('wallet.json'), null);
  if (!j) throw new Error('missing .state/wallet.json (cast wallet new --json format)');
  const w = Array.isArray(j) ? j[0] : j;
  return new ethers.Wallet(w.private_key, provider);
}

// Zendex key: random secp256k1 key separate from the EVM wallet, stored like the
// app's localStorage entry "0x<secret> 04<X><Y>". Circuits use (X mod p, Y mod p).
function zkey(address) {
  const all = readJson(f('zendex-key.json'), {});
  let rec = all[address.toLowerCase()];
  if (!rec) {
    const k = ethers.Wallet.createRandom();
    rec = `${k.privateKey} ${ethers.SigningKey.computePublicKey(k.privateKey, false).slice(2)}`;
    all[address.toLowerCase()] = rec;
    writeJson(f('zendex-key.json'), all);
  }
  const [secret, pub] = rec.split(' ');
  return { secret, pub, pkX: BigInt('0x' + pub.slice(2, 66)) % P, pkY: BigInt('0x' + pub.slice(66, 130)) % P };
}
// Fresh dust recipient per swap, derived from our Zendex secret so it stays recoverable.
export function dustWallet(secret, index) {
  const sk = BigInt(ethers.solidityPackedKeccak256(['bytes32', 'string', 'uint256'], [secret, 'agama-zendex-dust', index]));
  const n = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141n;
  return new ethers.Wallet(ethers.toBeHex((sk % (n - 1n)) + 1n, 32));
}

// ---------------- crypto ----------------
function randField() {
  for (;;) { const v = BigInt(ethers.hexlify(ethers.randomBytes(32))); if (v < P) return v; }
}
const commit = (assetId, amount, rho, k) => poseidon3([BigInt(assetId), BigInt(amount), poseidon3([rho, k.pkX, k.pkY])]);
const nullifierOf = (rho, k) => poseidon3([poseidon1([rho]), k.pkX, k.pkY]);
const tagOf = (epoch, commitment, salt) => poseidon3([BigInt(epoch), BigInt(commitment), BigInt(salt)]);
const ZERO = [0n];
for (let i = 1; i < 33; i++) ZERO.push(poseidon2([ZERO[i - 1], ZERO[i - 1]]));

const circuits = {};
function circuit(name) {
  if (!circuits[name]) {
    const file = path.join(DIR, 'circuits', `${name}.json`);
    if (!fs.existsSync(file)) throw new Error(`missing circuits/${name}.json: run \`node fetch-circuits.mjs\``);
    circuits[name] = JSON.parse(fs.readFileSync(file, 'utf8'));
  }
  return circuits[name];
}
// UltraHonk with keccak transcript, as the app passes to bb.js
async function prove(name, inputs) {
  const c = circuit(name);
  const backend = new UltraHonkBackend(c.bytecode, { threads: os.cpus().length });
  try {
    const { witness } = await new Noir(c).execute(inputs);
    const { proof, publicInputs } = await backend.generateProof(witness, { keccak: true });
    if (!(await backend.verifyProof({ proof, publicInputs }, { keccak: true }))) throw new Error(`${name}: local verification failed`);
    return { proof: ethers.hexlify(proof), publicInputs };
  } finally { await backend.destroy(); }
}

// ---------------- chain helpers ----------------
async function send(p) {
  const tx = await p;
  const r = await tx.wait();
  if (r.status !== 1) throw new Error(`tx reverted ${tx.hash}`);
  return r;
}
const tokenById = (id) => TOKENS[Number(id)];
function tokenBy(sym) {
  const t = TOKENS.find((x) => x.label.toLowerCase() === String(sym).toLowerCase() || String(x.id) === String(sym));
  if (!t) throw new Error(`unknown token ${sym}`);
  return t;
}
const fmt = (amount, t) => `${ethers.formatUnits(amount, t.decimals)} ${t.label}`;

async function leafEpochFromLogs(leaf, fromBlock) {
  const iface = new ethers.Interface(TREE_ABI);
  const topic = iface.getEvent('LeafInserted').topicHash;
  const latest = await provider.getBlockNumber();
  for (let b = fromBlock; b <= latest; b += 99_000) {
    const logs = await provider.getLogs({ address: TREE, topics: [topic, null, null, ethers.toBeHex(BigInt(leaf), 32)], fromBlock: b, toBlock: Math.min(b + 98_999, latest) });
    if (logs.length) return { epoch: iface.parseLog(logs[0]).args.epoch.toString(), tx: logs[0].transactionHash };
  }
  return null;
}

// ---------------- primitives ----------------
export async function faucet(sym, amountBase) {
  const w = wallet();
  const t = tokenBy(sym);
  if (t.id === 0) throw new Error('WZEN is wrapped from native ETH, not minted');
  const c = new ethers.Contract(t.address, ERC20, w);
  const hashes = [];
  let left = BigInt(amountBase);
  const cap = MINT_CAP * 10n ** BigInt(t.decimals);
  while (left > 0n) {
    const a = left > cap ? cap : left;
    const r = await send(c.mint(w.address, a));
    hashes.push(r.hash);
    const db = loadDb(); logTx(db, `faucet ${fmt(a, t)}`, r.hash); saveDb(db);
    left -= a;
  }
  return hashes;
}

// Mint only what the wallet lacks.
async function ensureWalletBalance(t, amount) {
  const w = wallet();
  const bal = await new ethers.Contract(t.address, ERC20, provider).balanceOf(w.address);
  if (bal >= amount) return [];
  return faucet(t.label, amount - bal);
}

// Deposit. The planned note is persisted before any tx so a crash can be recovered:
// if its commitment is on chain, the note is recovered from the LeafInserted event.
export async function deposit(sym, amountBase, tag = {}) {
  const w = wallet();
  const k = zkey(w.address);
  const t = tokenBy(sym);
  const amount = BigInt(amountBase);
  let db = loadDb();
  let plan = db.exec.pendingDeposit;
  if (plan && (plan.assetId !== t.id || plan.amount !== amount.toString())) throw new Error('another deposit is pending; run `status`');
  if (!plan) {
    const rho = randField();
    plan = { assetId: t.id, amount: amount.toString(), rho: rho.toString(), pkCommitment: commit(t.id, amount, rho, k).toString(), fromBlock: await provider.getBlockNumber(), ...tag };
    db.exec.pendingDeposit = plan; saveDb(db);
  }
  const recovered = await recoverPendingDeposit();
  if (recovered) return recovered;
  const pd = await prove('deposit', { asset_id: String(t.id), amount: plan.amount, commitment: plan.pkCommitment, pk_x: k.pkX.toString(), pk_y: k.pkY.toString(), rho: plan.rho });
  const token = new ethers.Contract(t.address, ERC20, w);
  if ((await token.allowance(w.address, VAULT_MANAGER)) < amount) {
    const ra = await send(token.approve(VAULT_MANAGER, amount));
    db = loadDb(); logTx(db, `approve ${t.label}`, ra.hash); saveDb(db);
  }
  const vm = new ethers.Contract(VAULT_MANAGER, VM_ABI, w);
  const r = await send(vm.deposit(pd, { gasLimit: await vm.deposit.estimateGas(pd) }));
  const iface = new ethers.Interface(TREE_ABI);
  const ev = r.logs.filter((l) => l.address.toLowerCase() === TREE.toLowerCase()).map((l) => iface.parseLog(l)).find((x) => x?.name === 'LeafInserted');
  return finalizeDeposit(plan, ev.args.epoch.toString(), r.hash);
}
function finalizeDeposit(plan, epochId, hash) {
  const db = loadDb();
  const { fromBlock, leg, ...rest } = plan;
  const note = { ref: nextRef(db), ...rest, epochId, timestamp: Date.now(), source: 'deposit', tx: hash };
  db.deposits.push(note);
  delete db.exec.pendingDeposit;
  const L = plan.leg && db.exec.window?.legs?.[plan.leg.index];
  if (L && L.cursor === plan.leg.step) { L.cursor += 1; L.note = note.ref; L.txs.deposit = hash; }
  logTx(db, `deposit ${fmt(plan.amount, tokenById(plan.assetId))}`, hash, { epochId });
  saveDb(db);
  return note;
}
async function recoverPendingDeposit() {
  const plan = loadDb().exec.pendingDeposit;
  if (!plan || !(await tree.commitments(BigInt(plan.pkCommitment)))) return null;
  const found = await leafEpochFromLogs(plan.pkCommitment, plan.fromBlock);
  if (!found) throw new Error('deposit commitment is on chain but its event was not found');
  return finalizeDeposit(plan, found.epoch, found.tx);
}

async function inclusionProof(note, salt) {
  const epoch = BigInt(note.epochId);
  const ht = await tree.getHistoricalTree(epoch);
  const hp = await tree.getHistoricalProof(BigInt(note.pkCommitment), epoch);
  const sib = [...hp.siblings], idx = [...hp.indices].map(Number);
  for (let o = sib.length; o < Number(ht.depth); o++) { sib.push(ZERO[o]); idx.push(0); }
  while (sib.length < 32) { sib.push(0n); idx.push(0); }
  return prove('inclusion', {
    merkle_root: ht.root.toString(), merkle_depth: hp.siblings.length.toString(), epoch_id: epoch.toString(),
    tag: tagOf(epoch, note.pkCommitment, salt).toString(), salt: salt.toString(), commitment: note.pkCommitment,
    merkle_proof: sib.map(String), merkle_indices: idx,
  });
}

function spendable(db, ref) {
  const note = db.deposits.find((n) => n.ref === ref || n.pkCommitment === ref);
  if (!note) throw new Error(`note ${ref} not found`);
  if (db.pendingRelays.some((p) => p.spent === note.pkCommitment)) throw new Error(`note ${note.ref} has a pending relay`);
  return note;
}

async function postJson(url, body, timeout) {
  const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), signal: AbortSignal.timeout(timeout) });
  return { status: r.status, body: await r.json().catch(() => null) };
}

// Sends a relay. The pending record (spent note, expected leaves and outputs) is
// persisted first; the note cannot be spent again until it is reconciled.
async function relayAndConfirm(action, proofs, pending) {
  let db = loadDb();
  db.pendingRelays.push({ ...pending, action, createdAt: Date.now() });
  saveDb(db);
  db.exec.relaysThisRun = (db.exec.relaysThisRun || 0) + 1; saveDb(db);
  let res;
  try { res = await postJson(`${RELAYER}/relay`, { action, proofs }, 75_000); } catch (e) { res = { status: 0, body: { error: { message: e.message } } }; }
  if (res.status >= 400 && res.status < 500 && res.status !== 409 && res.status !== 429) {
    db = loadDb(); db.pendingRelays = db.pendingRelays.filter((p) => p.id !== pending.id); saveDb(db);
    throw new Error(`relayer refused ${action}: HTTP ${res.status} ${JSON.stringify(res.body)}`);
  }
  const txHash = res.body?.data?.txHash;
  if (txHash) { db = loadDb(); const p = db.pendingRelays.find((x) => x.id === pending.id); if (p) p.txHash = txHash; saveDb(db); }
  const epochs = res.status === 200 && res.body?.status === 'success' ? res.body.data?.epochs : null;
  if (epochs && pending.leaves.every((l) => epochs[BigInt(l).toString()])) {
    return finalizeRelay(pending.id, txHash, Object.fromEntries(pending.leaves.map((l) => [l, String(epochs[BigInt(l).toString()])])), res.body.data.blockNumber);
  }
  return reconcileOne(pending.id, 90_000);
}

function finalizeRelay(id, txHash, epochsByLeaf, blockNumber) {
  const db = loadDb();
  const p = db.pendingRelays.find((x) => x.id === id);
  if (!p) return null;
  const spent = db.deposits.find((n) => n.pkCommitment === p.spent);
  db.deposits = db.deposits.filter((n) => n.pkCommitment !== p.spent);
  if (spent) db.spent.push({ ...spent, spentBy: txHash });
  const outs = p.outputs.map((o) => {
    const note = { ref: nextRef(db), ...o, epochId: epochsByLeaf[o.pkCommitment] ?? epochsByLeaf[ethers.toBeHex(BigInt(o.pkCommitment), 32)], timestamp: Date.now(), source: p.action, tx: txHash };
    db.deposits.push(note);
    return note;
  });
  db.pendingRelays = db.pendingRelays.filter((x) => x.id !== id);
  logTx(db, `${p.action} (relayed)`, txHash, { blockNumber, outputs: outs.map((o) => o.ref), dust: p.dust });
  if (p.leg) {
    const leg = db.exec.window?.legs?.[p.leg.index];
    if (leg && leg.cursor === p.leg.step) {
      leg.cursor += 1;
      leg.note = outs[p.leg.keep ?? 0].ref;
      leg.txs.swaps.push(txHash);
    }
  }
  saveDb(db);
  return { txHash, outputs: outs };
}

async function reconcileOne(id, waitMs) {
  const until = Date.now() + waitMs;
  for (;;) {
    const p = loadDb().pendingRelays.find((x) => x.id === id);
    if (!p) return null;
    const st = await postJson(`${RELAYER}/status`, { leaves: p.leaves, nullifiers: p.nullifiers, ...(p.txHash ? { txHash: p.txHash } : {}) }, 15_000).catch(() => null);
    const d = st?.body?.data;
    const found = p.leaves.map((l) => d?.leaves?.find((x) => x && BigInt(x.leaf) === BigInt(l)));
    if (found.every((x) => x?.inserted)) {
      return finalizeRelay(id, p.txHash || d?.tx?.hash, Object.fromEntries(p.leaves.map((l, i) => [ethers.toBeHex(BigInt(l), 32), String(found[i].epoch)])), d?.tx?.blockNumber);
    }
    const used = d?.nullifiers?.some((x) => x?.used);
    const txState = d?.tx?.status;
    if (!used && !found.some((x) => x?.inserted) && (txState === 'reverted' || (Date.now() - p.createdAt > PENDING_TIMEOUT_MS && txState !== 'pending'))) {
      // never landed: release the note so it can be spent again
      const db = loadDb(); db.pendingRelays = db.pendingRelays.filter((x) => x.id !== id); saveDb(db);
      console.log(`  relay ${p.action} ${p.txHash || ''} did not land, note released`);
      return null;
    }
    if (Date.now() > until) { console.log(`  relay ${p.action} still pending`); return 'pending'; }
    await new Promise((r) => setTimeout(r, 4000));
  }
}

export async function reconcileAll(waitMs = 0) {
  const pend = loadDb().pendingRelays;
  for (const p of pend) await reconcileOne(p.id, waitMs);
  await recoverPendingDeposit();
  return loadDb().pendingRelays.length === 0;
}

// Swap a whole note into outToken. dust (unused input) goes to a fresh derived address.
export async function swap(ref, outSym, minOutBase, leg) {
  const w = wallet();
  const k = zkey(w.address);
  let db = loadDb();
  const note = spendable(db, ref);
  const inT = tokenById(note.assetId), outT = tokenBy(outSym);
  if ((inT.id === 0) === (outT.id === 0)) throw new Error('only WZEN pairs are routed');
  const quote = (await router.getAmountsOut(BigInt(note.amount), [inT.address, outT.address]))[1];
  const minOut = minOutBase != null ? BigInt(minOutBase) : (quote * (10000n - SLIPPAGE_BPS)) / 10000n;
  if (minOut <= 0n) throw new Error('output rounds to zero');
  const dustIndex = db.exec.dustIndex; db.exec.dustIndex += 1; saveDb(db);
  const dust = dustWallet(k.secret, dustIndex).address;
  console.log(`  swap ${note.ref} ${fmt(note.amount, inT)} -> >= ${fmt(minOut, outT)} (quote ${fmt(quote, outT)}), dust #${dustIndex}`);
  const salt = randField();
  const incl = await inclusionProof(note, salt);
  const blk = await provider.getBlock('latest');
  const deadline = BigInt(Math.max(Math.floor(Date.now() / 1000), Number(blk.timestamp)) + 1800);
  const rho = BigInt(note.rho), swapRho = randField(), dustRho = randField();
  const swapCommitment = commit(outT.id, minOut, swapRho, k);
  const sp = await prove('swap', {
    asset_id: String(note.assetId), amount: note.amount, output_asset_id: String(outT.id), output_amount: minOut.toString(),
    deadline: deadline.toString(), nullifier: nullifierOf(rho, k).toString(), swap_commitment: swapCommitment.toString(),
    tag: tagOf(note.epochId, note.pkCommitment, salt).toString(), dust_recipient: dust,
    pk_x: k.pkX.toString(), pk_y: k.pkY.toString(), rho: rho.toString(), swap_rho: swapRho.toString(),
    dust_recipient_rho: dustRho.toString(), salt: salt.toString(), epoch_id: note.epochId, commitment: note.pkCommitment,
    dust_recipient_proof: poseidon2([BigInt(dust), dustRho]).toString(), tx_commitment: poseidon3([minOut, deadline, swapRho]).toString(),
  });
  const nul = sp.publicInputs[5].toLowerCase(), leaf = sp.publicInputs[6].toLowerCase();
  return relayAndConfirm('swap', [incl, sp], {
    id: nul, spent: note.pkCommitment, leaves: [leaf], nullifiers: [nul], dust: { index: dustIndex, address: dust },
    outputs: [{ pkCommitment: swapCommitment.toString(), rho: swapRho.toString(), assetId: outT.id, amount: minOut.toString() }], leg,
  });
}

// Split a note into (amount, remainder), both kept as shielded notes.
export async function split(ref, amountBase, leg) {
  const w = wallet();
  const k = zkey(w.address);
  const note = spendable(loadDb(), ref);
  const a = BigInt(note.amount), b = BigInt(amountBase), c = a - b;
  if (b <= 0n || c <= 0n) throw new Error('split amount must be strictly between 0 and the note amount');
  const salt = randField();
  const incl = await inclusionProof(note, salt);
  const rhoA = BigInt(note.rho), rhoB = randField(), rhoC = randField();
  const cb = commit(note.assetId, b, rhoB, k), cc = commit(note.assetId, c, rhoC, k);
  const sp = await prove('split', {
    nullifier_a: nullifierOf(rhoA, k).toString(), commitment_b: cb.toString(), commitment_c: cc.toString(),
    tag: tagOf(note.epochId, note.pkCommitment, salt).toString(), asset_id: String(note.assetId), amount_a: a.toString(),
    commitment_a: note.pkCommitment, amount_b: b.toString(), amount_c: c.toString(), pk_x: k.pkX.toString(), pk_y: k.pkY.toString(),
    rho_a: rhoA.toString(), rho_b: rhoB.toString(), rho_c: rhoC.toString(), epoch_id: note.epochId, salt: salt.toString(),
  });
  const nul = sp.publicInputs[0].toLowerCase();
  console.log(`  split ${note.ref} ${fmt(a, tokenById(note.assetId))} -> ${fmt(b, tokenById(note.assetId))} + remainder`);
  return relayAndConfirm('split', [incl, sp], {
    id: nul, spent: note.pkCommitment, leaves: [sp.publicInputs[1].toLowerCase(), sp.publicInputs[2].toLowerCase()], nullifiers: [nul],
    outputs: [
      { pkCommitment: cb.toString(), rho: rhoB.toString(), assetId: note.assetId, amount: b.toString() },
      { pkCommitment: cc.toString(), rho: rhoC.toString(), assetId: note.assetId, amount: c.toString() },
    ], leg: leg && { ...leg, keep: 0 },
  });
}

// ---------------- execute ----------------
// Plan for one hub leg at sandbox scale. Steps run in order; each is idempotent
// given the persisted state.
function planLeg(scaled, db) {
  const base = { asset: scaled.asset, name: scaled.name, side: scaled.side, hub_qty: scaled.hub_qty, hub_usdc: scaled.hub_usdc, cursor: 0, txs: { deposit: null, swaps: [] } };
  const sideName = scaled.side === 0 ? 'buy' : 'sell';
  if (scaled.asset === 1) return { ...base, status: 'skipped', reason: 'no venue on ZENDEX testnet' };
  if (BigInt(scaled.sandbox_usdc) < MIN_LEG_USDC) return { ...base, status: 'skipped', reason: `below minimum leg size (${ethers.formatUnits(scaled.sandbox_usdc, 6)} < ${ethers.formatUnits(MIN_LEG_USDC, 6)} tUSDC)` };
  if (scaled.asset === 3 && sideName === 'buy') return { ...base, status: 'planned', in: { token: 'tUSDC', amount: scaled.sandbox_usdc }, steps: [{ op: 'deposit' }, { op: 'swap', to: 'WZEN' }] };
  if (scaled.asset === 2 && sideName === 'buy') return { ...base, status: 'planned', in: { token: 'tUSDC', amount: scaled.sandbox_usdc }, steps: [{ op: 'deposit' }, { op: 'swap', to: 'WZEN' }, { op: 'swap', to: 'tcbBTC' }] };
  if (scaled.asset === 2) return { ...base, status: 'planned', in: { token: 'tcbBTC', amount: scaled.sandbox_qty }, steps: [{ op: 'deposit' }, { op: 'swap', to: 'WZEN' }, { op: 'swap', to: 'tUSDC' }] };
  // sell ZEN: spend WZEN inventory held in the pool
  const size = BigInt(scaled.sandbox_qty);
  const busy = new Set(db.pendingRelays.map((p) => p.spent));
  const inv = db.deposits.filter((n) => n.assetId === 0 && !busy.has(n.pkCommitment)).sort((x, y) => (BigInt(x.amount) < BigInt(y.amount) ? -1 : 1));
  const exact = inv.find((n) => BigInt(n.amount) === size);
  const bigger = inv.find((n) => BigInt(n.amount) > size);
  const smaller = [...inv].reverse().find((n) => BigInt(n.amount) < size);
  if (exact) return { ...base, status: 'planned', in: { token: 'WZEN', amount: exact.amount }, note: exact.ref, steps: [{ op: 'swap', to: 'tUSDC' }] };
  if (bigger) return { ...base, status: 'planned', in: { token: 'WZEN', amount: size.toString() }, note: bigger.ref, steps: [{ op: 'split', amount: size.toString() }, { op: 'swap', to: 'tUSDC' }] };
  if (smaller) return { ...base, status: 'planned', in: { token: 'WZEN', amount: smaller.amount }, note: smaller.ref, partial: true, steps: [{ op: 'swap', to: 'tUSDC' }] };
  return { ...base, status: 'skipped', reason: 'no WZEN inventory in the pool' };
}
// Testnet pool prices are synthetic and far from the exchange prices the hub
// trades at, so a sell sized by quantity would be worth almost anything. Every
// leg is sized by its USDC notional instead: a sell spends the amount of token
// the ZENDEX pools value at the leg's sandbox notional.
const SELL_ROUTE = { 2: ['tcbBTC', 'WZEN', 'tUSDC'], 3: ['WZEN', 'tUSDC'] };
async function sizeByNotional(scaled) {
  if (scaled.side !== 1 || !SELL_ROUTE[scaled.asset] || BigInt(scaled.sandbox_usdc) === 0n) return scaled;
  try {
    const path = SELL_ROUTE[scaled.asset].map((x) => tokenBy(x).address);
    const amounts = await router.getAmountsIn(BigInt(scaled.sandbox_usdc), path);
    return { ...scaled, sandbox_qty: amounts[0].toString() };
  } catch {
    return scaled; // not quotable: preflight skips the leg
  }
}
// Quotes the whole route on the ZENDEX pools before anything is sent. A leg whose
// route output rounds to (almost) nothing is skipped instead of executed.
const MIN_ROUTE_OUT = 1000n; // token base units
async function preflight(leg) {
  const route = [leg.in.token, ...leg.steps.filter((s) => s.op === 'swap').map((s) => s.to)].map((x) => tokenBy(x).address);
  try {
    const amounts = await router.getAmountsOut(BigInt(leg.in.amount), route);
    leg.route_quote = amounts.map(String);
    const last = amounts[amounts.length - 1];
    if (amounts.some((a) => a === 0n) || last < MIN_ROUTE_OUT) {
      leg.status = 'skipped';
      leg.reason = `route output too small on ZENDEX testnet pools (${route.length - 1} hops, final ${last} base units)`;
    }
  } catch (e) {
    leg.status = 'skipped';
    leg.reason = `route not quotable on ZENDEX: ${e.shortMessage || e.message}`;
  }
}
const relaysLeft = (leg) => leg.steps.slice(leg.cursor).filter((s) => s.op !== 'deposit').length;

function appendExecutionLog(w, leg, db) {
  const out = db.deposits.find((n) => n.ref === leg.note) || db.spent.find((n) => n.ref === leg.note);
  const line = {
    window: w.window, asset: leg.name, side: leg.side === 0 ? 'buy' : 'sell', hub_usdc: leg.hub_usdc, hub_qty: leg.hub_qty,
    sandbox_in: leg.in ? { token: leg.in.token, amount: ethers.formatUnits(leg.in.amount, tokenBy(leg.in.token).decimals) } : null,
    sandbox_out: leg.status !== 'skipped' && out ? { token: tokenById(out.assetId).label, amount: ethers.formatUnits(out.amount, tokenById(out.assetId).decimals) } : null,
    txs: leg.status !== 'skipped' ? leg.txs : null,
    ...(leg.status === 'skipped' ? { skipped: leg.reason } : {}),
    ...(leg.status === 'stopped' ? { stopped: leg.reason } : {}),
    ...(leg.partial ? { note: 'inventory smaller than the leg, sold the largest WZEN note available' } : {}),
    scale_down: Number(SCALE_DOWN),
    at: new Date().toISOString(),
  };
  fs.appendFileSync(EXECUTION_LOG, JSON.stringify(line) + '\n');
  return line;
}

export async function execute({ dryRun = false } = {}) {
  let db = loadDb();
  db.exec.relaysThisRun = 0; saveDb(db);
  if (!dryRun && !(await reconcileAll(90_000))) { console.log('pending relays are not settled yet, try again later'); return; }
  db = loadDb();
  if (!db.exec.window) {
    const entries = parseLog(fs.readFileSync(NETTING_LOG, 'utf8'));
    const sel = selectWindow(entries, db.exec.lastExecutedEpoch, FIRST_RUN_EPOCHS);
    const agg = aggregate(sel);
    if (!agg) { console.log(`no new epochs after ${db.exec.lastExecutedEpoch}`); return; }
    const legs = [];
    for (const l of agg.legs) legs.push(planLeg(await sizeByNotional(scaleLeg(l, SCALE_DOWN)), db));
    for (const l of legs) if (l.status === 'planned') await preflight(l);
    const w = { window: agg.window, epochs: agg.epochs, legs };
    console.log(`window ${agg.window[0]}..${agg.window[1]} (${agg.epochs} epochs), ${legs.length} net legs`);
    for (const l of legs) console.log(`  ${l.side === 0 ? 'buy' : 'sell'} ${l.name}: hub ${ethers.formatUnits(l.hub_qty, 6)} / ${ethers.formatUnits(l.hub_usdc, 6)} USDC -> ${l.status === 'skipped' ? 'skip: ' + l.reason : `${l.in.token} ${ethers.formatUnits(l.in.amount, tokenBy(l.in.token).decimals)}, ${l.steps.map((s) => s.op + (s.to ? '>' + s.to : '')).join(', ')}`}`);
    if (dryRun) return;
    db.exec.window = w; saveDb(db);
  } else console.log(`resuming window ${db.exec.window.window[0]}..${db.exec.window.window[1]}`);

  for (let i = 0; i < db.exec.window.legs.length; i++) {
    db = loadDb();
    const leg = db.exec.window.legs[i];
    if (leg.logged) continue;
    if (leg.status === 'planned') {
      if (relaysLeft(leg) > MAX_RELAYS - (db.exec.relaysThisRun || 0)) { console.log(`relay budget reached, ${leg.name} leg deferred to the next run`); return; }
      while (leg.cursor < leg.steps.length) {
        const step = leg.steps[leg.cursor];
        const tagLeg = { index: i, step: leg.cursor };
        if (step.op === 'deposit') {
          const t = tokenBy(leg.in.token);
          await ensureWalletBalance(t, BigInt(leg.in.amount));
          await deposit(t.label, leg.in.amount, { leg: tagLeg });
        } else if (step.op === 'split') {
          if ((await split(leg.note, step.amount, tagLeg)) === 'pending') return;
        } else {
          let r;
          try { r = await swap(leg.note, step.to, null, tagLeg); } catch (e) {
            if (!/rounds to zero/.test(e.message)) throw e;
            db = loadDb();
            Object.assign(db.exec.window.legs[i], { status: 'stopped', reason: `stopped before swap to ${step.to}: output rounds to zero on ZENDEX testnet pool` });
            saveDb(db);
            Object.assign(leg, db.exec.window.legs[i]);
            break;
          }
          if (r === 'pending') return;
          if (r === null) throw new Error('swap did not land; rerun `execute` to retry');
        }
        db = loadDb();
        Object.assign(leg, db.exec.window.legs[i]);
      }
      if (leg.status === 'planned') leg.status = 'done';
    }
    db = loadDb();
    const L = db.exec.window.legs[i];
    L.status = leg.status;
    console.log(JSON.stringify(appendExecutionLog(db.exec.window, L, db)));
    L.logged = true; saveDb(db);
  }
  db = loadDb();
  db.exec.lastExecutedEpoch = db.exec.window.window[1];
  delete db.exec.window; saveDb(db);
  console.log(`lastExecutedEpoch = ${db.exec.lastExecutedEpoch}`);
}

// ---------------- CLI ----------------
async function balances() {
  const w = wallet();
  const db = loadDb();
  console.log(`wallet ${w.address}  ETH ${ethers.formatEther(await provider.getBalance(w.address))}`);
  for (const t of TOKENS) console.log(`  ${t.label.padEnd(7)} ${ethers.formatUnits(await new ethers.Contract(t.address, ERC20, provider).balanceOf(w.address), t.decimals)}`);
  notes(db);
}
function notes(db = loadDb()) {
  console.log('shielded notes:');
  for (const n of db.deposits) console.log(`  ${n.ref.padEnd(4)} ${fmt(n.amount, tokenById(n.assetId)).padEnd(32)} epoch ${n.epochId}  (${n.source})`);
  console.log(`pending relays: ${db.pendingRelays.length}, lastExecutedEpoch: ${db.exec.lastExecutedEpoch ?? 'none'}${db.exec.window ? `, open window ${db.exec.window.window.join('..')}` : ''}`);
}
const units = (sym, human) => ethers.parseUnits(human, tokenBy(sym).decimals);

const COMMANDS = {
  faucet: async (sym = 'tUSDC', amt = '1000') => console.log(await faucet(sym, units(sym, amt))),
  deposit: async (sym, amt) => console.log(await deposit(sym, units(sym, amt))),
  swap: async (ref, out, minOut) => console.log(await swap(ref, out, minOut ? units(out, minOut) : null)),
  split: async (ref, amt) => { const n = loadDb().deposits.find((x) => x.ref === ref); console.log(await split(ref, ethers.parseUnits(amt, tokenById(n.assetId).decimals))); },
  balances, notes: async () => notes(),
  status: async () => { console.log((await reconcileAll(90_000)) ? 'no pending relays' : 'still pending'); notes(); },
  execute: async (...a) => execute({ dryRun: a.includes('--dry-run') }),
};
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [cmd, ...args] = process.argv.slice(2);
  if (!COMMANDS[cmd]) {
    console.log('usage: node zendex.mjs execute [--dry-run] | faucet [token] [amount] | deposit <token> <amount> | swap <note> <token> [minOut] | split <note> <amount> | balances | notes | status');
    process.exit(1);
  }
  COMMANDS[cmd](...args).then(() => process.exit(0)).catch((e) => { console.error('error:', e.shortMessage || e.message); process.exit(1); });
}
