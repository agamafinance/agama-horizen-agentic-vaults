import unittest

from netting import net

PRICES = [1_000_000, 2_500_000_000, 80_000_000_000, 6_000_000]


def order(asset, side, qty):
    return {"asset": asset, "side": side, "qty": qty}


class NettingTest(unittest.TestCase):
    def test_opposite_orders_cross_and_only_the_rest_goes_out(self):
        to_market, crossed = net({"a": [order(1, 0, 3_000_000)], "b": [order(1, 1, 1_000_000)]}, PRICES)
        self.assertEqual(crossed, [{"asset": 1, "qty": 1_000_000, "usdc": 2_500_000_000}])
        self.assertEqual(to_market, [{"asset": 1, "side": 0, "qty": 2_000_000, "usdc": 5_000_000_000}])

    def test_a_perfect_match_sends_nothing(self):
        to_market, crossed = net({"a": [order(3, 1, 5_000_000)], "b": [order(3, 0, 5_000_000)]}, PRICES)
        self.assertEqual(to_market, [])
        self.assertEqual(crossed[0]["qty"], 5_000_000)

    def test_one_sided_flow_goes_out_whole_and_per_asset(self):
        to_market, crossed = net({"a": [order(2, 1, 10_000), order(3, 0, 1_000_000)], "b": []}, PRICES)
        self.assertEqual(crossed, [])
        self.assertEqual([(o["asset"], o["side"], o["qty"]) for o in to_market], [(2, 1, 10_000), (3, 0, 1_000_000)])

    def test_cash_and_empty_orders_are_ignored(self):
        to_market, crossed = net({"a": [order(0, 0, 5), order(1, 0, 0)]}, PRICES)
        self.assertEqual((to_market, crossed), ([], []))


if __name__ == "__main__":
    unittest.main()
