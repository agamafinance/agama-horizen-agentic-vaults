// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {AgentVaultHub} from "../src/AgentVaultHub.sol";
import {EpochVerifier} from "../src/EpochVerifier.sol";
import {NetVerifier} from "../src/NetVerifier.sol";
import {NettingAttestor, IHub, INetVerifier} from "../src/NettingAttestor.sol";

/// Replays the netting proof built by zk/fixtures.py: at epoch 5 strategy 0
/// buys 100 ETH and 5,000 ZEN, strategy 1 sells 30 ETH and 0.5 BTC. The proof
/// opens both commitments the hub holds and shows the hub's net flow: buy 70
/// ETH and 5,000 ZEN, sell 0.5 BTC, 30 ETH crossed inside the batch.
contract NettingAttestorTest is Test {
    AgentVaultHub hub;
    NettingAttestor att;
    address a = address(0xA11CE);
    address b = address(0xB0B);
    uint64 constant GENESIS = 1_800_000_000;
    uint64 constant LEN = 300;

    bytes proof;
    bytes32 oc5a;
    bytes32 oc5b;
    uint64[4] netBuy;
    uint64[4] netSell;
    uint64[4] crossed;

    function setUp() public {
        string memory e = vm.readFile("test/fixtures/epochs.json");
        string memory j = vm.readFile("test/fixtures/netting.json");
        oc5a = vm.parseJsonBytes32(e, ".oc5");
        oc5b = vm.parseJsonBytes32(j, ".oc5b");
        uint256[] memory x = vm.parseJsonUintArray(j, ".net_buy");
        uint256[] memory y = vm.parseJsonUintArray(j, ".net_sell");
        uint256[] memory z = vm.parseJsonUintArray(j, ".crossed");
        for (uint256 i = 0; i < 4; i++) {
            netBuy[i] = uint64(x[i]);
            netSell[i] = uint64(y[i]);
            crossed[i] = uint64(z[i]);
        }
        proof = vm.readFileBinary("test/fixtures/net_e5.bin");

        hub = new AgentVaultHub(address(new EpochVerifier()), address(0x0AC1E), GENESIS, LEN, 1_000_000_000_000);
        att = new NettingAttestor(IHub(address(hub)), INetVerifier(address(new NetVerifier())));
        vm.prank(a);
        hub.register("momentum", 0x0E, 5_000);
        vm.prank(b);
        hub.register("mean-reversion", 0x0E, 5_000);
    }

    function _commitBoth() internal {
        vm.warp(GENESIS + 5 * LEN + 10);
        vm.prank(a);
        hub.commitOrders(0, 5, oc5a);
        vm.prank(b);
        hub.commitOrders(1, 5, oc5b);
    }

    function _close() internal {
        vm.warp(hub.closesAt(5) + 1);
    }

    function test_net_flow_is_proven_from_the_committed_orders() public {
        _commitBoth();
        _close();
        att.attest(5, netBuy, netSell, crossed, proof);

        NettingAttestor.NetFlow memory f = att.flow(5);
        assertTrue(f.proven);
        assertEq(f.strategies, 2);
        assertEq(f.netBuy[1], 70_000_000); // 70 ETH to buy
        assertEq(f.netBuy[3], 5_000_000_000); // 5,000 ZEN to buy
        assertEq(f.netSell[2], 500_000); // 0.5 BTC to sell
        assertEq(f.crossed[1], 30_000_000); // 30 ETH crossed inside the batch
        assertEq(att.epochsProven(), 1);
    }

    /// Before the close a strategy could still commit, so the batch is not final.
    function test_attesting_before_the_close_is_refused() public {
        _commitBoth();
        uint64 closes = hub.closesAt(5);
        vm.expectRevert(abi.encodeWithSelector(NettingAttestor.EpochStillOpen.selector, uint64(5), closes));
        att.attest(5, netBuy, netSell, crossed, proof);
    }

    /// A better looking net flow typed next to a real proof does not verify.
    function test_altered_net_flow_is_refused() public {
        _commitBoth();
        _close();
        netBuy[1] -= 1;
        vm.expectRevert();
        att.attest(5, netBuy, netSell, crossed, proof);
    }

    /// Leaving a strategy out: a third strategy committed, the proof covers two,
    /// and the contract builds the batch from the hub, so it fails.
    function test_a_strategy_left_out_of_the_batch_is_refused() public {
        address c = address(0xCA);
        vm.prank(c);
        hub.register("third", 0x0E, 5_000);
        _commitBoth();
        vm.prank(c);
        hub.commitOrders(2, 5, keccak256("other orders"));
        _close();
        vm.expectRevert();
        att.attest(5, netBuy, netSell, crossed, proof);
    }

    /// A batch missing a commitment the proof opened fails too.
    function test_a_strategy_that_did_not_commit_cannot_be_counted() public {
        vm.warp(GENESIS + 5 * LEN + 10);
        vm.prank(a);
        hub.commitOrders(0, 5, oc5a);
        _close();
        vm.expectRevert();
        att.attest(5, netBuy, netSell, crossed, proof);
    }

    function test_an_epoch_is_attested_once() public {
        _commitBoth();
        _close();
        att.attest(5, netBuy, netSell, crossed, proof);
        vm.expectRevert(abi.encodeWithSelector(NettingAttestor.AlreadyProven.selector, uint64(5)));
        att.attest(5, netBuy, netSell, crossed, proof);
    }

    function test_an_epoch_without_orders_has_nothing_to_attest() public {
        vm.warp(hub.closesAt(5) + 1);
        vm.expectRevert(abi.encodeWithSelector(NettingAttestor.NothingCommitted.selector, uint64(5)));
        att.attest(5, netBuy, netSell, crossed, proof);
    }
}
