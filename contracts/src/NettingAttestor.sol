// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface INetVerifier {
    function verify(bytes calldata proof, bytes32[] calldata publicInputs) external view returns (bool);
}

interface IHub {
    function orderCommit(uint256 id, uint64 epoch) external view returns (bytes32);
    function strategyCount() external view returns (uint256);
    function closesAt(uint64 epoch) external view returns (uint64);
}

/// @title NettingAttestor
/// @notice Records the hub's net flow for an epoch, proven from the orders every
/// strategy committed before the close. The proof opens each commitment the hub
/// stored; this contract checks that no strategy that committed was left out. So
/// the net flow sent to market is exactly the sum of the committed orders, while
/// the orders themselves stay private.
contract NettingAttestor {
    uint256 public constant SLOTS = 4; // strategy slots per batch, as in net_epoch
    uint256 public constant ASSETS = 4; // USDC, ETH, BTC, ZEN

    IHub public immutable hub;
    INetVerifier public immutable verifier;

    struct NetFlow {
        uint64[ASSETS] netBuy;
        uint64[ASSETS] netSell;
        uint64[ASSETS] crossed;
        uint8 strategies;
        bool proven;
    }

    mapping(uint64 => NetFlow) internal flows;
    uint64 public lastEpoch;
    uint256 public epochsProven;

    event NetFlowProven(
        uint64 indexed epoch, uint64[ASSETS] netBuy, uint64[ASSETS] netSell, uint64[ASSETS] crossed, uint8 strategies
    );

    error EpochStillOpen(uint64 epoch, uint64 closesAt);
    error AlreadyProven(uint64 epoch);
    error NothingCommitted(uint64 epoch);
    error TooManyStrategies(uint64 epoch);
    error BadProof();

    constructor(IHub hub_, INetVerifier verifier_) {
        hub = hub_;
        verifier = verifier_;
    }

    /// @notice Anyone may attest; the proof is the only authority. The batch is
    /// read from the hub, not passed in: every strategy with a commitment for the
    /// epoch is in it, in id order.
    function attest(
        uint64 epoch,
        uint64[ASSETS] calldata netBuy,
        uint64[ASSETS] calldata netSell,
        uint64[ASSETS] calldata crossed,
        bytes calldata proof
    ) external {
        uint64 closes = hub.closesAt(epoch);
        if (block.timestamp < closes) revert EpochStillOpen(epoch, closes); // no commitment can arrive later
        if (flows[epoch].proven) revert AlreadyProven(epoch);

        // public inputs, in the circuit's order: epoch, ids, commits, active, then the outputs
        bytes32[] memory pi = new bytes32[](1 + 3 * SLOTS + 3 * ASSETS);
        pi[0] = bytes32(uint256(epoch));
        uint256 n;
        uint256 count = hub.strategyCount();
        for (uint256 id; id < count; id++) {
            bytes32 c = hub.orderCommit(id, epoch);
            if (c == bytes32(0)) continue;
            if (n == SLOTS) revert TooManyStrategies(epoch);
            pi[1 + n] = bytes32(id);
            pi[1 + SLOTS + n] = c;
            pi[1 + 2 * SLOTS + n] = bytes32(uint256(1));
            n++;
        }
        if (n == 0) revert NothingCommitted(epoch);
        uint256 o = 1 + 3 * SLOTS;
        for (uint256 a; a < ASSETS; a++) {
            pi[o + a] = bytes32(uint256(netBuy[a]));
            pi[o + ASSETS + a] = bytes32(uint256(netSell[a]));
            pi[o + 2 * ASSETS + a] = bytes32(uint256(crossed[a]));
        }
        if (!verifier.verify(proof, pi)) revert BadProof();

        flows[epoch] = NetFlow(netBuy, netSell, crossed, uint8(n), true);
        if (epoch > lastEpoch) lastEpoch = epoch;
        epochsProven++;
        emit NetFlowProven(epoch, netBuy, netSell, crossed, uint8(n));
    }

    function flow(uint64 epoch) external view returns (NetFlow memory) {
        return flows[epoch];
    }
}
