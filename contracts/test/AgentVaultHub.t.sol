// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentVaultHub} from "../src/AgentVaultHub.sol";
import {EpochVerifier} from "../src/EpochVerifier.sol";

/// Replays the two proofs built by zk/fixtures.py: strategy 0 starts at epoch
/// 5 from 1,000,000 USDC of sandbox cash, buys ETH and ZEN, then trims ETH at
/// epoch 6. Every attack below uses a real proof and changes one thing.
contract AgentVaultHubTest is Test {
    AgentVaultHub hub;
    address strategist = address(0xA11CE);
    address oracle = address(0x0AC1E);
    uint64 constant GENESIS = 1_800_000_000;
    uint64 constant LEN = 300;

    bytes proof5;
    bytes proof6;
    bytes32 oc5;
    bytes32 nc5;
    uint64 nav5;
    bytes32 oc6;
    bytes32 nc6;
    uint64 nav6;
    uint64[4] p5;
    uint64[4] p6;

    function setUp() public {
        string memory j = vm.readFile("test/fixtures/epochs.json");
        oc5 = vm.parseJsonBytes32(j, ".oc5");
        nc5 = vm.parseJsonBytes32(j, ".nc5");
        nav5 = uint64(vm.parseJsonUint(j, ".nav5"));
        oc6 = vm.parseJsonBytes32(j, ".oc6");
        nc6 = vm.parseJsonBytes32(j, ".nc6");
        nav6 = uint64(vm.parseJsonUint(j, ".nav6"));
        uint256[] memory a = vm.parseJsonUintArray(j, ".prices5");
        uint256[] memory b = vm.parseJsonUintArray(j, ".prices6");
        for (uint256 i = 0; i < 4; i++) {
            p5[i] = uint64(a[i]);
            p6[i] = uint64(b[i]);
        }
        proof5 = vm.readFileBinary("test/fixtures/proof_e5.bin");
        proof6 = vm.readFileBinary("test/fixtures/proof_e6.bin");

        hub = new AgentVaultHub(address(new EpochVerifier()), oracle, GENESIS, LEN, uint64(vm.parseJsonUint(j, ".capital")));
        vm.prank(strategist);
        hub.register("momentum", 0x0E, 5_000);
    }

    function _open(uint64 epoch) internal view returns (uint256) {
        return GENESIS + uint256(epoch) * LEN + 10;
    }

    function _closed(uint64 epoch) internal view returns (uint256) {
        return hub.closesAt(epoch) + 1;
    }

    function _epoch5() internal {
        vm.warp(_open(5));
        vm.prank(strategist);
        hub.commitOrders(0, 5, oc5);
        vm.warp(_closed(5));
        vm.prank(oracle);
        hub.postPrices(5, p5);
        vm.prank(strategist);
        hub.settle(0, 5, nc5, nav5, proof5);
    }

    // ------------------------------------------------------------ honest path

    function test_two_epochs_settle_and_build_a_track_record() public {
        _epoch5();
        vm.warp(_open(6));
        vm.prank(strategist);
        hub.commitOrders(0, 6, oc6);
        vm.warp(_closed(6));
        vm.prank(oracle);
        hub.postPrices(6, p6);
        vm.prank(strategist);
        hub.settle(0, 6, nc6, nav6, proof6);

        AgentVaultHub.Strategy memory s = hub.strategy(0);
        assertEq(s.book, nc6);
        assertEq(s.nav, 1_011_000_000_000);
        assertEq(s.epochsSettled, 2);
        assertEq(hub.navAt(0, 5), 1_000_000_000_000);
        assertEq(hub.returnBps(0), 110); // +1.10%
    }

    // ----------------------------------------------------------- the attacks

    /// Hindsight: orders posted once the epoch is over are refused.
    function test_orders_after_the_close_are_refused() public {
        vm.warp(_closed(5));
        uint64 closes = hub.closesAt(5);
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(AgentVaultHub.EpochClosed.selector, uint64(5), closes));
        hub.commitOrders(0, 5, oc5);
    }

    /// Inflated NAV: a real proof with a better number typed in does not verify.
    function test_inflated_nav_is_refused() public {
        vm.warp(_open(5));
        vm.prank(strategist);
        hub.commitOrders(0, 5, oc5);
        vm.warp(_closed(5));
        vm.prank(oracle);
        hub.postPrices(5, p5);
        vm.prank(strategist);
        vm.expectRevert();
        hub.settle(0, 5, nc5, nav5 + 50_000_000_000, proof5);
    }

    /// Swapped orders: committing one set and proving another does not verify.
    function test_proof_for_other_orders_is_refused() public {
        vm.warp(_open(5));
        vm.prank(strategist);
        hub.commitOrders(0, 5, keccak256("a different order set"));
        vm.warp(_closed(5));
        vm.prank(oracle);
        hub.postPrices(5, p5);
        vm.prank(strategist);
        vm.expectRevert();
        hub.settle(0, 5, nc5, nav5, proof5);
    }

    /// Other prices: a proof built on prices the oracle did not post fails.
    function test_proof_on_other_prices_is_refused() public {
        vm.warp(_open(5));
        vm.prank(strategist);
        hub.commitOrders(0, 5, oc5);
        vm.warp(_closed(5));
        vm.prank(oracle);
        hub.postPrices(5, p6);
        vm.prank(strategist);
        vm.expectRevert();
        hub.settle(0, 5, nc5, nav5, proof5);
    }

    /// Stale book: epoch 6's proof opens epoch 5's book, so it cannot be
    /// settled on a strategy that never settled epoch 5.
    function test_skipping_the_book_it_builds_on_is_refused() public {
        vm.warp(_open(6));
        vm.prank(strategist);
        hub.commitOrders(0, 6, oc6);
        vm.warp(_closed(6));
        vm.prank(oracle);
        hub.postPrices(6, p6);
        vm.prank(strategist);
        vm.expectRevert();
        hub.settle(0, 6, nc6, nav6, proof6);
    }

    /// Replay: an epoch cannot be settled twice.
    function test_settling_the_same_epoch_twice_is_refused() public {
        _epoch5();
        vm.prank(strategist);
        vm.expectRevert(abi.encodeWithSelector(AgentVaultHub.EpochNotAfterLast.selector, uint64(5), uint64(5)));
        hub.settle(0, 5, nc5, nav5, proof5);
    }

    // ------------------------------------------------------ ordering and roles

    function test_prices_cannot_be_posted_before_the_close() public {
        vm.warp(_open(5));
        uint64 closes = hub.closesAt(5);
        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(AgentVaultHub.EpochStillOpen.selector, uint64(5), closes));
        hub.postPrices(5, p5);
    }

    function test_only_the_oracle_posts_prices() public {
        vm.warp(_closed(5));
        vm.expectRevert(AgentVaultHub.NotOracle.selector);
        hub.postPrices(5, p5);
    }

    function test_only_the_owner_commits_orders() public {
        vm.warp(_open(5));
        vm.expectRevert(AgentVaultHub.NotOwner.selector);
        hub.commitOrders(0, 5, oc5);
    }

    function test_orders_are_committed_once() public {
        vm.warp(_open(5));
        vm.startPrank(strategist);
        hub.commitOrders(0, 5, oc5);
        vm.expectRevert(AgentVaultHub.AlreadyCommitted.selector);
        hub.commitOrders(0, 5, keccak256("second thoughts"));
        vm.stopPrank();
    }

    function test_mandate_must_allow_a_non_cash_asset() public {
        vm.expectRevert(AgentVaultHub.BadMandate.selector);
        hub.register("cash only", 0x01, 5_000);
    }
}
