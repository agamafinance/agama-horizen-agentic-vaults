// Pure functions: netting log window -> net hub flow per asset -> sandbox legs.
// Units follow agents/run.py: prices in 1e-6 USDC per whole asset, qty in 1e-6
// asset units, usdc in 1e-6 USDC. Asset 1 ETH, 2 BTC, 3 ZEN. Side 0 buy, 1 sell.

export const ASSET_NAMES = { 1: 'ETH', 2: 'BTC', 3: 'ZEN' };

export function parseLog(text) {
  return text.split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
}

// Epochs strictly after lastExecutedEpoch. On the first run (no lastExecutedEpoch)
// only the last `firstRunCap` epochs are taken.
export function selectWindow(entries, lastExecutedEpoch, firstRunCap = 20) {
  const sorted = [...entries].sort((a, b) => a.epoch - b.epoch);
  let sel = lastExecutedEpoch == null ? sorted.slice(-firstRunCap) : sorted.filter((e) => e.epoch > lastExecutedEpoch);
  return sel;
}

// Net hub flow per asset over a window. Buys count positive, sells negative.
// hub_usdc is the net USDC of the window when it has the same sign as the net
// quantity, otherwise the net quantity valued at the window's last price.
export function aggregate(entries) {
  if (!entries.length) return null;
  const acc = {};
  let lastPrices = null;
  for (const e of entries) {
    lastPrices = e.prices;
    for (const o of e.to_market || []) {
      const a = (acc[o.asset] ||= { qty: 0n, usdc: 0n });
      const s = o.side === 0 ? 1n : -1n;
      a.qty += s * BigInt(o.qty);
      a.usdc += s * BigInt(o.usdc);
    }
  }
  const legs = [];
  for (const asset of Object.keys(acc).map(Number).sort((x, y) => x - y)) {
    const { qty, usdc } = acc[asset];
    if (qty === 0n) continue;
    const side = qty > 0n ? 0 : 1;
    const absQty = qty < 0n ? -qty : qty;
    const sameSign = (usdc > 0n && qty > 0n) || (usdc < 0n && qty < 0n);
    const price = BigInt(lastPrices[asset]);
    const hubUsdc = sameSign ? (usdc < 0n ? -usdc : usdc) : (absQty * price) / 1_000_000n;
    legs.push({ asset, name: ASSET_NAMES[asset], side, hub_qty: absQty.toString(), hub_usdc: hubUsdc.toString() });
  }
  return { window: [entries[0].epoch, entries[entries.length - 1].epoch], epochs: entries.length, legs };
}

// Hub leg -> sandbox amounts in token base units (tUSDC 6, tcbBTC 8, WZEN 18 decimals).
export function scaleLeg(leg, scaleDown) {
  const k = BigInt(scaleDown);
  const usdc = BigInt(leg.hub_usdc) / k; // tUSDC base units (1e-6)
  const qty = BigInt(leg.hub_qty);
  const decimalsUp = { 1: 12n, 2: 2n, 3: 12n }[leg.asset]; // 1e-6 units -> token base units
  const assetUnits = (qty * 10n ** decimalsUp) / k;
  return { ...leg, sandbox_usdc: usdc.toString(), sandbox_qty: assetUnits.toString() };
}
