// Agama agentic vaults: one strategy, one epoch.
//
// A strategy keeps a private book: how much of each asset it holds. On chain
// there is only a commitment to that book. Each epoch the strategy commits to
// its orders before the epoch closes, the closing prices are posted after, and
// this circuit proves the transition:
//
//   - the old book is the one the chain already holds a commitment to
//   - the orders are exactly the ones committed before the close, so nothing
//     can be added or dropped once the prices are known
//   - every order is filled at the posted closing price, and no balance goes
//     negative
//   - the resulting book respects the strategy's public mandate: allowed
//     assets, and a cap on the weight of any single non-cash asset
//   - the NAV published on chain is the value of that book at those prices
//
// The chain learns the new commitment and the NAV. It never learns a balance,
// an order, or the logic that produced them.
//
// Units: every quantity is in millionths of the asset. Prices are in
// millionths of a USDC per whole unit of the asset. Asset 0 is USDC itself, so
// its price is fixed at one.

global A: u32 = 4; // 0 USDC, 1 ETH, 2 BTC, 3 ZEN
global K: u32 = 4; // orders per strategy per epoch
global SCALE: u128 = 1_000_000;

pub struct Order {
    asset: u8, // 0 marks an empty slot
    side: u8, // 0 buy, 1 sell
    qty: u64,
}

fn book_commit(strategy_id: Field, bal: [u64; A], salt: Field) -> Field {
    std::hash::pedersen_hash([strategy_id, bal[0] as Field, bal[1] as Field, bal[2] as Field, bal[3] as Field, salt])
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

fn value(qty: u64, price: u64) -> u128 {
    (qty as u128) * (price as u128) / SCALE
}

fn main(
    old_bal: [u64; A],
    old_salt: Field,
    orders: [Order; K],
    orders_salt: Field,
    new_salt: Field,
    strategy_id: pub Field,
    epoch: pub Field,
    old_commit: pub Field,
    orders_commit: pub Field,
    prices: pub [u64; A],
    allowed_mask: pub u8,
    max_weight_bps: pub u64,
    is_genesis: pub bool,
    genesis_capital: pub u64,
) -> pub (Field, u64) {
    assert(prices[0] == SCALE as u64, "USDC must be priced at one");

    // The starting book. At genesis it is public by construction: all cash,
    // no positions, so the first NAV cannot be invented. After that it must
    // open the commitment the chain holds.
    let mut bal = old_bal;
    if is_genesis {
        assert(old_commit == 0, "genesis has no prior commitment");
        assert(old_bal[0] == genesis_capital, "genesis starts in cash");
        for i in 1..A {
            assert(old_bal[i] == 0, "genesis holds no positions");
        }
    } else {
        assert(book_commit(strategy_id, old_bal, old_salt) == old_commit, "book does not open the commitment");
    }

    assert(orders_hash(strategy_id, epoch, orders, orders_salt) == orders_commit, "orders differ from the committed ones");

    for i in 0..K {
        let o = orders[i];
        if o.qty == 0 {
            assert((o.asset == 0) & (o.side == 0), "empty slot must be zeroed");
        } else {
            let a = o.asset as u32;
            assert((a >= 1) & (a < A), "unknown asset");
            assert(((allowed_mask >> o.asset) & 1) == 1, "asset outside the mandate");
            assert(o.side <= 1, "unknown side");
            let cash = value(o.qty, prices[a]) as u64;
            if o.side == 0 {
                assert(bal[0] >= cash, "not enough cash");
                bal[0] -= cash;
                bal[a] += o.qty;
            } else {
                assert(bal[a] >= o.qty, "selling more than held");
                bal[a] -= o.qty;
                bal[0] += cash;
            }
        }
    }

    let mut nav: u128 = 0;
    for i in 0..A {
        nav += value(bal[i], prices[i]);
    }
    for i in 1..A {
        assert(value(bal[i], prices[i]) * 10_000 <= (max_weight_bps as u128) * nav, "position above the mandate weight cap");
    }

    (book_commit(strategy_id, bal, new_salt), nav as u64)
}

#[test]
fn genesis_buy_then_value() {
    let prices = [1_000_000, 2_500_000_000, 60_000_000_000, 8_000_000];
    let orders = [
        Order { asset: 1, side: 0, qty: 100_000_000 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
    ];
    let oc = orders_hash(7, 1, orders, 42);
    let (_, nav) = main([1_000_000_000_000, 0, 0, 0], 0, orders, 42, 9, 7, 1, 0, oc, prices, 14, 5_000, true, 1_000_000_000_000);
    assert(nav == 1_000_000_000_000);
}

#[test(should_fail_with = "orders differ from the committed ones")]
fn swapped_orders_are_refused() {
    let prices = [1_000_000, 2_500_000_000, 60_000_000_000, 8_000_000];
    let committed = [
        Order { asset: 1, side: 0, qty: 100_000_000 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
    ];
    let oc = orders_hash(7, 1, committed, 42);
    let other = [
        Order { asset: 1, side: 0, qty: 200_000_000 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
    ];
    let _ = main([1_000_000_000_000, 0, 0, 0], 0, other, 42, 9, 7, 1, 0, oc, prices, 14, 5_000, true, 1_000_000_000_000);
}

#[test(should_fail_with = "position above the mandate weight cap")]
fn weight_cap_is_enforced() {
    let prices = [1_000_000, 2_500_000_000, 60_000_000_000, 8_000_000];
    let orders = [
        Order { asset: 1, side: 0, qty: 300_000_000 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
    ];
    let oc = orders_hash(7, 1, orders, 42);
    // 300 ETH at 2,500 = 750k of a 1M book, above a 50% cap
    let _ = main([1_000_000_000_000, 0, 0, 0], 0, orders, 42, 9, 7, 1, 0, oc, prices, 14, 5_000, true, 1_000_000_000_000);
}

#[test(should_fail_with = "asset outside the mandate")]
fn mandate_assets_are_enforced() {
    let prices = [1_000_000, 2_500_000_000, 60_000_000_000, 8_000_000];
    let orders = [
        Order { asset: 3, side: 0, qty: 1_000_000 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
        Order { asset: 0, side: 0, qty: 0 },
    ];
    let oc = orders_hash(7, 1, orders, 42);
    // mask allows ETH and BTC only
    let _ = main([1_000_000_000_000, 0, 0, 0], 0, orders, 42, 9, 7, 1, 0, oc, prices, 6, 5_000, true, 1_000_000_000_000);
}
