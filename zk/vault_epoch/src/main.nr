// Agama agentic vaults v2: one strategy vault, one epoch, with depositors.
//
// Same private book and commit-before-outcome as strategy_epoch, plus the
// vault's capital flows, which are public: USDC deposited during the epoch and
// shares redeemed. The circuit proves:
//
//   - the old book opens the commitment the chain holds (or is empty at genesis)
//   - the orders are exactly the ones committed before the close
//   - every order fills at the posted closing price, no balance goes negative
//   - the NAV is the value of the book after the fills, before any flow; the
//     contract prices deposits and redemptions at that NAV per share
//   - redemptions are paid in cash at that price, the cash is there, and the
//     deposits are added to cash
//   - the book after the flows respects the mandate: allowed assets, and a cap
//     on the weight of any single non-cash asset
//
// The chain learns the new commitment, the NAV and the cash paid out. Never a
// balance, an order, or the logic that produced them.
//
// Units: quantities in millionths of the asset, prices in millionths of a USDC
// per whole unit, shares in millionths. Asset 0 is USDC, priced at one.

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
    inflow: pub u64,
    redeem_shares: pub u64,
    total_shares: pub u64,
) -> pub (Field, u64, u64) {
    assert(prices[0] == SCALE as u64, "USDC must be priced at one");

    // The starting book: empty before the first settlement, so no NAV can be
    // invented; after that it must open the commitment the chain holds.
    if old_commit == 0 {
        for i in 0..A {
            assert(old_bal[i] == 0, "a new vault starts empty");
        }
        assert(total_shares == 0, "a new vault has no shares");
    } else {
        assert(book_commit(strategy_id, old_bal, old_salt) == old_commit, "book does not open the commitment");
    }

    assert(orders_hash(strategy_id, epoch, orders, orders_salt) == orders_commit, "orders differ from the committed ones");

    let mut bal = old_bal;
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

    // NAV after the fills, before the flows: the price of a share this epoch
    let mut nav: u128 = 0;
    for i in 0..A {
        nav += value(bal[i], prices[i]);
    }

    // redemptions are paid in cash at that price
    assert(redeem_shares as u128 <= total_shares as u128, "redeeming more shares than exist");
    let mut outflow: u128 = 0;
    if total_shares != 0 {
        outflow = nav * (redeem_shares as u128) / (total_shares as u128);
    }
    let cash = (bal[0] as u128) + (inflow as u128);
    assert(cash >= outflow, "not enough cash for the redemptions");
    bal[0] = (cash - outflow) as u64;

    let mut nav_after: u128 = 0;
    for i in 0..A {
        nav_after += value(bal[i], prices[i]);
    }
    for i in 1..A {
        assert(value(bal[i], prices[i]) * 10_000 <= (max_weight_bps as u128) * nav_after, "position above the mandate weight cap");
    }

    (book_commit(strategy_id, bal, new_salt), nav as u64, outflow as u64)
}

fn none() -> Order {
    Order { asset: 0, side: 0, qty: 0 }
}

global P: [u64; A] = [1_000_000, 2_500_000_000, 60_000_000_000, 8_000_000];

#[test]
fn first_deposit_then_trade_and_redeem() {
    // epoch 1: a new vault receives 10,000 USDC, no orders yet
    let empty = [none(), none(), none(), none()];
    let oc1 = orders_hash(3, 1, empty, 5);
    let (c1, nav1, out1) = main([0, 0, 0, 0], 0, empty, 5, 11, 3, 1, 0, oc1, P, 14, 5_000, 10_000_000_000, 0, 0);
    assert(nav1 == 0);
    assert(out1 == 0);
    // the contract mints 10,000 shares 1:1 for the first deposit
    // epoch 2: buy 1 ETH at 2,500, then redeem a quarter of the shares at the NAV
    let buy = [Order { asset: 1, side: 0, qty: 1_000_000 }, none(), none(), none()];
    let oc2 = orders_hash(3, 2, buy, 6);
    let (_, nav2, out2) = main(
        [10_000_000_000, 0, 0, 0], 11, buy, 6, 12, 3, 2, c1, oc2, P, 14, 5_000, 0, 2_500_000_000, 10_000_000_000,
    );
    assert(nav2 == 10_000_000_000);
    assert(out2 == 2_500_000_000);
}

#[test(should_fail_with = "a new vault starts empty")]
fn a_new_vault_cannot_invent_a_book() {
    let empty = [none(), none(), none(), none()];
    let oc = orders_hash(3, 1, empty, 5);
    let _ = main([1_000_000, 0, 0, 0], 0, empty, 5, 11, 3, 1, 0, oc, P, 14, 5_000, 0, 0, 0);
}

#[test(should_fail_with = "not enough cash for the redemptions")]
fn redemptions_need_cash() {
    // 10,000 USDC, all of it but 1,000 bought into ETH and BTC, then everyone redeems
    let empty = [none(), none(), none(), none()];
    let oc1 = orders_hash(3, 1, empty, 5);
    let (c1, _, _) = main([0, 0, 0, 0], 0, empty, 5, 11, 3, 1, 0, oc1, P, 14, 5_000, 10_000_000_000, 0, 0);
    let buy = [Order { asset: 1, side: 0, qty: 1_800_000 }, Order { asset: 2, side: 0, qty: 75_000 }, none(), none()];
    let oc2 = orders_hash(3, 2, buy, 6);
    let _ = main(
        [10_000_000_000, 0, 0, 0], 11, buy, 6, 12, 3, 2, c1, oc2, P, 14, 5_000, 0, 10_000_000_000, 10_000_000_000,
    );
}

#[test(should_fail_with = "orders differ from the committed ones")]
fn orders_other_than_committed_are_refused() {
    let empty = [none(), none(), none(), none()];
    let oc1 = orders_hash(3, 1, empty, 5);
    let (c1, _, _) = main([0, 0, 0, 0], 0, empty, 5, 11, 3, 1, 0, oc1, P, 14, 5_000, 10_000_000_000, 0, 0);
    let buy = [Order { asset: 1, side: 0, qty: 1_000_000 }, none(), none(), none()];
    let bigger = [Order { asset: 1, side: 0, qty: 1_500_000 }, none(), none(), none()];
    let oc2 = orders_hash(3, 2, buy, 6);
    let _ = main([10_000_000_000, 0, 0, 0], 11, bigger, 6, 12, 3, 2, c1, oc2, P, 14, 5_000, 0, 0, 10_000_000_000);
}

#[test(should_fail_with = "position above the mandate weight cap")]
fn redemptions_cannot_leave_the_book_over_its_cap() {
    // 4,000 of ETH in a 10,000 vault is 40%; after 5,000 is redeemed it is 80%
    let empty = [none(), none(), none(), none()];
    let oc1 = orders_hash(3, 1, empty, 5);
    let (c1, _, _) = main([0, 0, 0, 0], 0, empty, 5, 11, 3, 1, 0, oc1, P, 14, 5_000, 10_000_000_000, 0, 0);
    let buy = [Order { asset: 1, side: 0, qty: 1_600_000 }, none(), none(), none()];
    let oc2 = orders_hash(3, 2, buy, 6);
    let _ = main(
        [10_000_000_000, 0, 0, 0], 11, buy, 6, 12, 3, 2, c1, oc2, P, 14, 5_000, 0, 5_000_000_000, 10_000_000_000,
    );
}

#[test(should_fail_with = "redeeming more shares than exist")]
fn cannot_redeem_more_than_the_supply() {
    let empty = [none(), none(), none(), none()];
    let oc1 = orders_hash(3, 1, empty, 5);
    let (c1, _, _) = main([0, 0, 0, 0], 0, empty, 5, 11, 3, 1, 0, oc1, P, 14, 5_000, 10_000_000_000, 0, 0);
    let oc2 = orders_hash(3, 2, empty, 6);
    let _ = main([10_000_000_000, 0, 0, 0], 11, empty, 6, 12, 3, 2, c1, oc2, P, 14, 5_000, 0, 10_000_000_001, 10_000_000_000);
}
