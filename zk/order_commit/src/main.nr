// Off-chain helper. Computes the commitment a strategy posts before an epoch
// closes, with the same hash the settlement circuit checks against. It proves
// nothing and never goes on chain; it only saves reimplementing Pedersen.

global K: u32 = 4;

fn main(strategy_id: Field, epoch: Field, assets: [u8; K], sides: [u8; K], qtys: [u64; K], salt: Field) -> pub Field {
    let mut xs: [Field; 3 * K + 3] = [0; 3 * K + 3];
    xs[0] = strategy_id;
    xs[1] = epoch;
    for i in 0..K {
        xs[2 + 3 * i] = assets[i] as Field;
        xs[3 + 3 * i] = sides[i] as Field;
        xs[4 + 3 * i] = qtys[i] as Field;
    }
    xs[3 * K + 2] = salt;
    std::hash::pedersen_hash(xs)
}
