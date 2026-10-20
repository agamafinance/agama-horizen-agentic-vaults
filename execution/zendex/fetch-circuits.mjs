#!/usr/bin/env node
// Downloads the public ZENDEX testnet app, extracts the compiled Noir circuits
// embedded in its main bundle and writes them to circuits/<name>.json.
// Circuits are identified by their ABI parameter names, never by minified
// variable names. The bundle is parsed as data: only object, array, string,
// number and boolean literals are accepted, nothing from it is executed.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const APP = process.env.ZENDEX_APP_URL || 'https://testnet.zendex.fi';
const NOIR_VERSION = '1.0.0-beta.7';

// ordered ABI parameter names of each circuit used by the app
export const SIGNATURES = {
  deposit: 'asset_id,amount,commitment,pk_x,pk_y,rho',
  inclusion: 'merkle_root,merkle_depth,epoch_id,tag,salt,commitment,merkle_proof,merkle_indices',
  swap: 'asset_id,amount,output_asset_id,output_amount,deadline,nullifier,swap_commitment,tag,dust_recipient,pk_x,pk_y,rho,swap_rho,dust_recipient_rho,salt,epoch_id,commitment,dust_recipient_proof,tx_commitment',
  split: 'nullifier_a,commitment_b,commitment_c,tag,asset_id,amount_a,commitment_a,amount_b,amount_c,pk_x,pk_y,rho_a,rho_b,rho_c,epoch_id,salt',
  join: 'nullifier_a,nullifier_b,commitment_c,tag_a,tag_b,asset_id,amount_a,amount_b,amount_c,commitment_a,commitment_b,pk_x,pk_y,rho_a,rho_b,rho_c,epoch_id_a,epoch_id_b,salt_a,salt_b',
  withdraw: 'asset_id,amount,nullifier,tag,recipient,rho,salt,epoch_id,commitment,pk_x,pk_y,recipient_proof',
  addLiquidity: 'asset_id,amount,slippage,deadline,nullifier,liquidity_commitment,tag,dust_recipient,pk_x,pk_y,rho,liquidity_rho,dust_recipient_rho,salt,epoch_id,commitment,tx_commitment,dust_recipient_proof',
  removeLiquidity: 'asset_id,amount,slippage,deadline,liquidity_nullifier,liquidity_commitment,tag,recipient,pk_x,pk_y,liquidity_rho,recipient_rho,liquidity_salt,liquidity_epoch_id,tx_commitment,recipient_proof',
  createOrder: 'asset_id_in,asset_id_out,amount_in,amount_out,nullifier,spot_commitment,execute_commitment,cancel_commitment,tag,pk_x,pk_y,rho,spot_rho,salt,epoch_id,commitment',
  cancelOrder: 'spot_commitment,pk_x,pk_y,spot_rho,asset_id_in,asset_id_out,amount_in,amount_out',
};
const REQUIRED = ['deposit', 'inclusion', 'swap', 'split'];

// Minimal parser for a JS object literal (minified output): {a:1,"b":'x',c:[!0,null]}
export function parseLiteral(src, start) {
  let i = start;
  const ws = () => { while (/\s/.test(src[i])) i++; };
  const fail = (m) => { throw new Error(`literal parse error at ${i}: ${m}`); };
  function str() {
    const q = src[i++];
    let out = '';
    for (;;) {
      const c = src[i++];
      if (c === undefined) fail('unterminated string');
      if (c === q) return out;
      if (c === '\\') {
        const e = src[i++];
        if (e === 'n') out += '\n'; else if (e === 't') out += '\t'; else if (e === 'r') out += '\r';
        else if (e === 'b') out += '\b'; else if (e === 'f') out += '\f'; else if (e === 'v') out += '\v';
        else if (e === '0' && !/[0-9]/.test(src[i])) out += '\0';
        else if (e === 'x') { out += String.fromCharCode(parseInt(src.slice(i, i + 2), 16)); i += 2; }
        else if (e === 'u') {
          if (src[i] === '{') { const j = src.indexOf('}', i); out += String.fromCodePoint(parseInt(src.slice(i + 1, j), 16)); i = j + 1; }
          else { out += String.fromCharCode(parseInt(src.slice(i, i + 4), 16)); i += 4; }
        } else if (e === '\n') { /* line continuation */ } else out += e;
      } else if (q === '`' && c === '$' && src[i] === '{') fail('template expression');
      else out += c;
    }
  }
  function key() {
    ws();
    if (src[i] === '"' || src[i] === "'") return str();
    const m = /^[A-Za-z_$0-9]+/.exec(src.slice(i, i + 256));
    if (!m) fail('bad key');
    i += m[0].length;
    return m[0];
  }
  function value() {
    ws();
    const c = src[i];
    if (c === '{') {
      i++; const o = {};
      ws(); if (src[i] === '}') { i++; return o; }
      for (;;) {
        const k = key(); ws();
        if (src[i++] !== ':') fail('expected :');
        o[k] = value(); ws();
        if (src[i] === ',') { i++; continue; }
        if (src[i] === '}') { i++; return o; }
        fail('expected , or }');
      }
    }
    if (c === '[') {
      i++; const a = [];
      ws(); if (src[i] === ']') { i++; return a; }
      for (;;) {
        a.push(value()); ws();
        if (src[i] === ',') { i++; continue; }
        if (src[i] === ']') { i++; return a; }
        fail('expected , or ]');
      }
    }
    if (c === '"' || c === "'" || c === '`') return str();
    if (src.startsWith('!0', i)) { i += 2; return true; }
    if (src.startsWith('!1', i)) { i += 2; return false; }
    for (const [w, v] of [['true', true], ['false', false], ['null', null]]) if (src.startsWith(w, i)) { i += w.length; return v; }
    const m = /^-?(\d+\.?\d*(e[+-]?\d+)?|\.\d+(e[+-]?\d+)?)/i.exec(src.slice(i, i + 64));
    if (m) { i += m[0].length; return Number(m[0]); }
    fail(`unsupported token ${JSON.stringify(src.slice(i, i + 20))}`);
  }
  const v = value();
  return { value: v, end: i };
}

export function extractCircuits(bundle) {
  const found = {};
  let i = 0;
  while ((i = bundle.indexOf('{noir_version:', i)) !== -1) {
    const { value, end } = parseLiteral(bundle, i);
    i = end;
    const names = value?.abi?.parameters?.map((p) => p.name).join(',');
    const kind = Object.keys(SIGNATURES).find((k) => SIGNATURES[k] === names);
    if (!kind) { console.warn(`unrecognised circuit: ${names}`); continue; }
    if (!String(value.noir_version).startsWith(NOIR_VERSION + '+') && value.noir_version !== NOIR_VERSION)
      throw new Error(`${kind}: noir_version ${value.noir_version}, expected ${NOIR_VERSION}`);
    if (typeof value.bytecode !== 'string' || !value.bytecode.length) throw new Error(`${kind}: no bytecode`);
    found[kind] = value;
  }
  return found;
}

async function main() {
  const html = await (await fetch(APP + '/')).text();
  const m = /<script[^>]+src="([^"]*\/assets\/index-[^"]+\.js)"/.exec(html);
  if (!m) throw new Error('main bundle not found in index.html');
  const url = new URL(m[1], APP + '/').href;
  const bundle = await (await fetch(url)).text();
  console.log(`bundle ${url} (${bundle.length} bytes)`);
  const circuits = extractCircuits(bundle);
  const missing = REQUIRED.filter((k) => !circuits[k]);
  if (missing.length) throw new Error(`missing circuits: ${missing.join(', ')}`);
  const out = path.join(DIR, 'circuits');
  fs.mkdirSync(out, { recursive: true });
  const manifest = { source: url, fetchedAt: new Date().toISOString(), circuits: {} };
  for (const [k, c] of Object.entries(circuits)) {
    const json = JSON.stringify(c);
    fs.writeFileSync(path.join(out, `${k}.json`), json);
    manifest.circuits[k] = { noir_version: c.noir_version, bytecodeSha256: crypto.createHash('sha256').update(c.bytecode).digest('hex') };
    console.log(`  ${k.padEnd(16)} ${c.noir_version}  ${manifest.circuits[k].bytecodeSha256.slice(0, 16)}`);
  }
  fs.writeFileSync(path.join(out, 'manifest.json'), JSON.stringify(manifest, null, 2));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main().catch((e) => { console.error('error:', e.message); process.exit(1); });
