import test from 'node:test';
import assert from 'node:assert/strict';
import { parseLog, selectWindow, aggregate, scaleLeg } from './aggregate.mjs';

const P = [1000000, 2000000000, 80000000000, 6000000]; // USDC, ETH 2000, BTC 80000, ZEN 6
const line = (epoch, to_market, prices = P) => ({ epoch, prices, crossed: [], to_market });

test('selectWindow takes epochs after the last executed one', () => {
  const log = [line(3, []), line(1, []), line(2, []), line(4, [])];
  assert.deepEqual(selectWindow(log, 2).map((e) => e.epoch), [3, 4]);
  assert.deepEqual(selectWindow(log, 4), []);
});

test('selectWindow caps the first run to the last N epochs', () => {
  const log = Array.from({ length: 30 }, (_, i) => line(100 + i, []));
  const w = selectWindow(log, undefined, 20);
  assert.equal(w.length, 20);
  assert.equal(w[0].epoch, 110);
  assert.equal(w.at(-1).epoch, 129);
});

test('aggregate nets buys against sells per asset', () => {
  const w = [
    line(1, [{ asset: 2, side: 0, qty: 1_000_000, usdc: 80_000_000_000 }, { asset: 3, side: 1, qty: 5_000_000, usdc: 30_000_000 }]),
    line(2, [{ asset: 2, side: 1, qty: 400_000, usdc: 32_000_000_000 }, { asset: 3, side: 1, qty: 1_000_000, usdc: 6_000_000 }]),
  ];
  const r = aggregate(w);
  assert.deepEqual(r.window, [1, 2]);
  assert.deepEqual(r.legs, [
    { asset: 2, name: 'BTC', side: 0, hub_qty: '600000', hub_usdc: '48000000000' },
    { asset: 3, name: 'ZEN', side: 1, hub_qty: '6000000', hub_usdc: '36000000' },
  ]);
});

test('aggregate drops assets that net to zero', () => {
  const w = [
    line(1, [{ asset: 1, side: 0, qty: 2_000_000, usdc: 4_000_000_000 }]),
    line(2, [{ asset: 1, side: 1, qty: 2_000_000, usdc: 4_100_000_000 }]),
  ];
  assert.deepEqual(aggregate(w).legs, []);
});

test('aggregate values the net quantity at the last price when the USDC sign disagrees', () => {
  const w = [
    line(1, [{ asset: 1, side: 0, qty: 2_000_000, usdc: 4_000_000_000 }]),
    line(2, [{ asset: 1, side: 1, qty: 1_900_000, usdc: 4_500_000_000 }], [1000000, 2500000000, 80000000000, 6000000]),
  ];
  const [leg] = aggregate(w).legs;
  assert.equal(leg.side, 0);
  assert.equal(leg.hub_qty, '100000');
  assert.equal(leg.hub_usdc, '250000000'); // 0.1 ETH at 2500
});

test('aggregate of an empty window is null', () => {
  assert.equal(aggregate([]), null);
});

test('scaleLeg converts to sandbox token base units', () => {
  const btc = scaleLeg({ asset: 2, side: 0, hub_qty: '1202115', hub_usdc: '99226983862' }, 10000);
  assert.equal(btc.sandbox_usdc, '9922698'); // 9.922698 tUSDC
  assert.equal(btc.sandbox_qty, '12021'); // tcbBTC, 8 decimals
  const zen = scaleLeg({ asset: 3, side: 1, hub_qty: '5000000', hub_usdc: '30000000' }, 10000);
  assert.equal(zen.sandbox_qty, '500000000000000'); // 0.0005 WZEN, 18 decimals
});

test('parseLog ignores blank lines', () => {
  assert.equal(parseLog('{"epoch":1,"to_market":[]}\n\n{"epoch":2,"to_market":[]}\n').length, 2);
});
