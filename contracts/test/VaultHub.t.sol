// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {VaultHub} from "../src/VaultHub.sol";
import {VaultVerifier} from "../src/VaultVerifier.sol";

contract Token is ERC20 {
    uint8 internal immutable d;

    constructor(string memory n, uint8 d_) ERC20(n, n) {
        d = d_;
    }

    function decimals() public view override returns (uint8) {
        return d;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// Replays the three vault proofs built by zk/fixtures.py. Strategy 0 receives
/// 10,000 USDC at epoch 5, buys 1 ETH at 2,600 at epoch 6, and at epoch 7, with
/// ETH at 3,000, pays a redemption of a quarter of its shares at the proven NAV
/// and takes its performance fee. Every attack uses a real proof and changes
/// one thing.
contract VaultHubTest is Test {
    VaultHub hub;
    Token usdc;
    Token zen;
    address strategist = address(0xA11CE);
    address alice = address(0xA1);
    address oracle = address(0x0AC1E);
    address treasury = address(0x7EA);
    uint64 constant GENESIS = 1_800_000_000;
    uint64 constant LEN = 300;
    uint256 constant BOND = 100 ether; // 100 ZEN
    uint256 constant PER_ZEN = 1_000_000_000; // 1,000 USDC of capacity per ZEN

    string j;
    uint64 dep;
    uint64 redeem;

    function setUp() public {
        j = vm.readFile("test/fixtures/vault.json");
        dep = uint64(vm.parseJsonUint(j, ".deposit"));
        redeem = uint64(vm.parseJsonUint(j, ".redeem"));
        usdc = new Token("tUSDC", 6);
        zen = new Token("ZEN", 18);
        hub = new VaultHub(address(new VaultVerifier()), oracle, GENESIS, LEN, address(usdc), address(zen), treasury, 10 ether, PER_ZEN);
        zen.mint(strategist, BOND);
        usdc.mint(strategist, 50_000_000_000);
        usdc.mint(alice, 50_000_000_000);
        vm.startPrank(strategist);
        zen.approve(address(hub), BOND);
        usdc.approve(address(hub), type(uint256).max);
        hub.register("momentum", 0x0E, 5_000, 2_000, BOND);
        vm.stopPrank();
        vm.prank(alice);
        usdc.approve(address(hub), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _at(uint64 epoch) internal {
        vm.warp(GENESIS + uint256(epoch) * LEN + 10);
    }

    function _prices(uint64 e) internal view returns (uint64[4] memory p) {
        uint256[] memory a = vm.parseJsonUintArray(j, string.concat(".e", vm.toString(e), ".prices"));
        for (uint256 i = 0; i < 4; i++) {
            p[i] = uint64(a[i]);
        }
    }

    function _b(uint64 e, string memory k) internal view returns (bytes32) {
        return vm.parseJsonBytes32(j, string.concat(".e", vm.toString(e), ".", k));
    }

    function _u(uint64 e, string memory k) internal view returns (uint64) {
        return uint64(vm.parseJsonUint(j, string.concat(".e", vm.toString(e), ".", k)));
    }

    function _proof(uint64 e) internal view returns (bytes memory) {
        return vm.readFileBinary(string.concat("test/fixtures/vault_e", vm.toString(e), ".bin"));
    }

    /// commit during the epoch, close it, post its prices
    function _run(uint64 e) internal {
        _at(e);
        vm.prank(strategist);
        hub.commitOrders(0, e, _b(e, "oc"));
        vm.warp(hub.closesAt(e) + 1);
        vm.prank(oracle);
        hub.postPrices(e, _prices(e));
    }

    function _settle(uint64 e) internal {
        vm.prank(strategist);
        hub.settle(0, e, _b(e, "book"), _u(e, "nav"), _u(e, "outflow"), _proof(e));
    }

    /// epoch 5 deposit and settlement, epoch 6 trade, and the redemption
    /// requested during 6 for 7
    function _toEpoch7() internal {
        _at(5);
        vm.prank(strategist);
        hub.deposit(0, dep);
        _run(5);
        _settle(5);
        vm.prank(strategist);
        hub.claim(0, 5);
        _at(6);
        vm.prank(strategist);
        hub.requestRedeem(0, redeem);
        _run(6);
        _settle(6);
        _run(7);
    }

    // ------------------------------------------------------------ honest path

    function test_deposit_trade_redeem_at_the_proven_nav() public {
        _toEpoch7();
        _settle(7);

        VaultHub.Strategy memory s = hub.strategy(0);
        // NAV 10,400 before the flows: 7,400 cash and 1 ETH at 3,000
        assertEq(_u(7, "nav"), 10_400_000_000);
        // a quarter of the shares is paid a quarter of the NAV, in cash
        assertEq(_u(7, "outflow"), 2_600_000_000);
        uint256 before = usdc.balanceOf(strategist);
        vm.prank(strategist);
        hub.claim(0, 7);
        assertEq(usdc.balanceOf(strategist) - before, 2_600_000_000);
        // 10% of the 4% gain went to fees, in shares, half to the treasury
        assertGt(hub.sharesOf(0, treasury), 0);
        assertEq(s.nav, 7_800_000_000);
        assertEq(s.epochsSettled, 3);
        assertGt(s.sharePrice, 1_030_000);
        assertEq(s.highWaterMark, s.sharePrice);
        assertEq(usdc.balanceOf(address(hub)), dep - 2_600_000_000);
    }

    // ----------------------------------------------------------- the attacks

    function test_inflated_nav_is_refused() public {
        _toEpoch7();
        vm.prank(strategist);
        vm.expectRevert();
        hub.settle(0, 7, _b(7, "book"), _u(7, "nav") + 1_000_000_000, _u(7, "outflow"), _proof(7));
    }

    /// Short-paying redeemers: a smaller payout typed next to a real proof fails.
    function test_short_paid_redemptions_are_refused() public {
        _toEpoch7();
        vm.prank(strategist);
        vm.expectRevert();
        hub.settle(0, 7, _b(7, "book"), _u(7, "nav"), _u(7, "outflow") - 1, _proof(7));
    }

    /// The flows are public inputs the contract fills in: a deposit the proof
    /// left out makes it fail, so no depositor can be skipped.
    function test_proof_ignoring_a_new_deposit_is_refused() public {
        _at(5);
        vm.prank(strategist);
        hub.deposit(0, dep);
        _run(5);
        _settle(5);
        _at(6);
        vm.prank(strategist);
        hub.deposit(0, 1_000_000); // one more USDC the epoch 6 proof does not know about
        _run(6);
        vm.prank(strategist);
        vm.expectRevert();
        hub.settle(0, 6, _b(6, "book"), _u(6, "nav"), _u(6, "outflow"), _proof(6));
    }

    function test_settling_twice_is_refused() public {
        _toEpoch7();
        _settle(7);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(VaultHub.EpochNotAfterLast.selector, uint64(7), uint64(7)));
        hub.settle(0, 7, _b(7, "book"), _u(7, "nav"), _u(7, "outflow"), _proof(7));
    }

    // ------------------------------------------------- lifecycle and the bond

    function test_outsiders_cannot_deposit_during_the_sandbox() public {
        _at(5);
        vm.prank(alice);
        vm.expectRevert(VaultHub.SandboxOnly.selector);
        hub.deposit(0, 1_000_000);
    }

    function test_the_bond_caps_the_capital() public {
        _at(5);
        uint64 cap = hub.capacity(0); // 100 ZEN x 1,000 USDC
        assertEq(cap, 100_000_000_000);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(VaultHub.OverCapacity.selector, cap));
        hub.deposit(0, cap + 1);
    }

    function test_a_vault_that_stops_proving_is_slashed_and_depositors_exit() public {
        _toEpoch7();
        _settle(7);
        vm.prank(alice);
        vm.expectRevert(VaultHub.NotSlashable.selector);
        hub.slash(0);

        vm.warp(hub.closesAt(7 + hub.MISSED_EPOCHS_LIMIT()) + 1);
        vm.prank(alice);
        hub.slash(0);
        assertEq(zen.balanceOf(treasury), BOND);
        assertTrue(hub.strategy(0).frozen);

        // the strategist's own shares exit at the last proven NAV per share
        uint64 sh = hub.sharesOf(0, strategist);
        VaultHub.Strategy memory s = hub.strategy(0);
        uint256 before = usdc.balanceOf(strategist);
        vm.prank(strategist);
        hub.exitFrozen(0);
        assertEq(usdc.balanceOf(strategist) - before, uint256(sh) * s.nav / s.totalShares);
    }

    function test_a_deposit_whose_epoch_was_skipped_is_refunded() public {
        _at(5);
        vm.prank(strategist);
        hub.deposit(0, dep);
        _run(5);
        _settle(5);
        _at(6);
        vm.prank(strategist);
        hub.deposit(0, 5_000_000);
        vm.prank(strategist);
        vm.expectRevert(VaultHub.StillSettleable.selector);
        hub.reclaim(0, 6);
        // epoch 6 is never settled; the window passes
        vm.warp(hub.closesAt(6 + hub.MISSED_EPOCHS_LIMIT()) + 1);
        uint256 before = usdc.balanceOf(strategist);
        vm.prank(strategist);
        hub.reclaim(0, 6);
        assertEq(usdc.balanceOf(strategist) - before, 5_000_000);
    }

    function test_a_strategist_with_no_depositors_retires_and_gets_the_bond_back() public {
        vm.prank(strategist);
        hub.retire(0);
        assertEq(zen.balanceOf(strategist), BOND);
    }

    function test_a_strategist_cannot_retire_while_holding_deposits() public {
        _at(5);
        vm.prank(strategist);
        hub.deposit(0, dep);
        vm.prank(strategist);
        vm.expectRevert(VaultHub.HasDepositors.selector);
        hub.retire(0);
    }

    function test_registration_needs_a_bond() public {
        vm.prank(alice);
        vm.expectRevert(VaultHub.BondTooSmall.selector);
        hub.register("no bond", 0x0E, 5_000, 2_000, 1 ether);
    }

    function test_redemptions_wait_for_the_next_epoch() public {
        _at(5);
        vm.prank(strategist);
        hub.deposit(0, dep);
        _run(5);
        _settle(5);
        vm.prank(strategist);
        hub.claim(0, 5);
        _at(6);
        vm.prank(strategist);
        hub.requestRedeem(0, redeem);
        assertEq(hub.redeemsIn(0, 7), redeem);
        assertEq(hub.redeemsIn(0, 6), 0);
    }
}
