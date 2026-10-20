// Netting proof for one epoch.
//
// Opens every strategy's committed orders for the epoch, with the hash the hub
// stored before the close, and proves the hub's net flow per asset: what was
// crossed between strategies and what is left to buy or sell on the market.
// The orders stay private; the chain learns only the totals.
//
// Units match strategy_epoch: quantities in millionths of an asset, side 0 buys,
// side 1 sells, asset 0 (USDC) marks an empty slot.

global A: u32 = 4; // USDC, ETH, BTC, ZEN
global K: u32 = 4; // orders per strategy
global S: u32 = 4; // strategy slots per batch

pub struct Order {
    asset: u8,
    side: u8,
    qty: u64,
}

fn orders_hash(strategy_id: Field, epoch: Field, orders: [Order; K], salt: Field) -> Field {
    let mut xs: [Field; 3 * K + 3] = [0; 3 * K + 3];
    xs[0] = strategy_id;
    xs[1] = epoch;
    for i in 0..K {
        xs[2 + 3 * i] = orders[i].asset as Field;
        xs[3 + 3 * i] = orders[i].side as Field;
        xs[4 + 3 * i] = orders[i].qty as Field;
    }
    xs[3 * K + 2] = salt;
    std::hash::pedersen_hash(xs)
}

fn main(
    orders: [[Order; K]; S],
    salts: [Field; S],
    epoch: pub Field,
    ids: pub [Field; S],
    commits: pub [Field; S],
    active: pub [bool; S],
) -> pub ([u64; A], [u64; A], [u64; A]) {
    let mut bought: [u128; A] = [0; A];
    let mut sold: [u128; A] = [0; A];
    for s in 0..S {
        if active[s] {
            // the orders are exactly the ones committed on chain before the close
            assert(orders_hash(ids[s], epoch, orders[s], salts[s]) == commits[s], "orders do not open the commitment");
            for i in 0..K {
                let o = orders[s][i];
                assert(o.asset < 4, "unknown asset");
                assert(o.side < 2, "bad side");
                if (o.asset != 0) & (o.qty != 0) {
                    if o.side == 0 {
                        bought[o.asset as u32] += o.qty as u128;
                    } else {
                        sold[o.asset as u32] += o.qty as u128;
                    }
                }
            }
        } else {
            // an empty slot carries nothing
            assert(commits[s] == 0, "inactive slot with a commitment");
            for i in 0..K {
                assert(orders[s][i].qty == 0, "inactive slot with orders");
            }
        }
    }
    let mut net_buy: [u64; A] = [0; A];
    let mut net_sell: [u64; A] = [0; A];
    let mut crossed: [u64; A] = [0; A];
    for a in 1..A {
        if bought[a] >= sold[a] {
            crossed[a] = sold[a] as u64;
            net_buy[a] = (bought[a] - sold[a]) as u64;
        } else {
            crossed[a] = bought[a] as u64;
            net_sell[a] = (sold[a] - bought[a]) as u64;
        }
    }
    (net_buy, net_sell, crossed)
}

fn none() -> Order {
    Order { asset: 0, side: 0, qty: 0 }
}

fn book(o0: Order, o1: Order) -> [Order; K] {
    [o0, o1, none(), none()]
}

fn empty() -> [Order; K] {
    [none(), none(), none(), none()]
}

#[test]
fn opposite_orders_cross_and_the_rest_is_net() {
    let a = book(Order { asset: 1, side: 0, qty: 3_000_000 }, Order { asset: 3, side: 1, qty: 500 });
    let b = book(Order { asset: 1, side: 1, qty: 1_000_000 }, none());
    let (net_buy, net_sell, crossed) = main(
        [a, b, empty(), empty()],
        [7, 8, 0, 0],
        42,
        [0, 1, 0, 0],
        [orders_hash(0, 42, a, 7), orders_hash(1, 42, b, 8), 0, 0],
        [true, true, false, false],
    );
    assert(crossed[1] == 1_000_000);
    assert(net_buy[1] == 2_000_000);
    assert(net_sell[1] == 0);
    assert(net_sell[3] == 500);
    assert(net_buy[2] + net_sell[2] + crossed[2] == 0);
}

#[test(should_fail_with = "orders do not open the commitment")]
fn orders_other_than_committed_are_refused() {
    let a = book(Order { asset: 1, side: 0, qty: 3_000_000 }, none());
    let bigger = book(Order { asset: 1, side: 0, qty: 9_000_000 }, none());
    let _ = main(
        [bigger, empty(), empty(), empty()],
        [7, 0, 0, 0],
        42,
        [0, 0, 0, 0],
        [orders_hash(0, 42, a, 7), 0, 0, 0],
        [true, false, false, false],
    );
}

#[test(should_fail_with = "orders do not open the commitment")]
fn orders_from_another_epoch_are_refused() {
    let a = book(Order { asset: 2, side: 1, qty: 10_000 }, none());
    let _ = main(
        [a, empty(), empty(), empty()],
        [7, 0, 0, 0],
        43,
        [0, 0, 0, 0],
        [orders_hash(0, 42, a, 7), 0, 0, 0],
        [true, false, false, false],
    );
}

#[test(should_fail_with = "inactive slot with orders")]
fn orders_hidden_in_an_empty_slot_are_refused() {
    let a = book(Order { asset: 2, side: 1, qty: 10_000 }, none());
    let _ = main(
        [empty(), a, empty(), empty()],
        [0, 7, 0, 0],
        42,
        [0, 0, 0, 0],
        [0, 0, 0, 0],
        [false, false, false, false],
    );
}
