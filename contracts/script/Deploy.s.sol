// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {AgentVaultHub} from "../src/AgentVaultHub.sol";
import {EpochVerifier} from "../src/EpochVerifier.sol";

/// Deploy the verifier and the hub.
///
///   ORACLE=0x... EPOCH_LEN=240 forge script script/Deploy.s.sol \
///     --rpc-url horizen_testnet --broadcast --private-key $PK
///
/// On testnet the oracle is a key that posts exchange closing prices. On
/// mainnet it becomes a contract reading Stork, which is live on Horizen.
contract Deploy is Script {
    function run() external {
        address oracle = vm.envOr("ORACLE", msg.sender);
        uint64 epochLen = uint64(vm.envOr("EPOCH_LEN", uint256(240)));
        uint64 genesis = uint64(vm.envOr("GENESIS", block.timestamp));
        uint64 capital = uint64(vm.envOr("CAPITAL", uint256(1_000_000_000_000))); // 1,000,000 USDC

        vm.startBroadcast();
        EpochVerifier verifier = new EpochVerifier();
        AgentVaultHub hub = new AgentVaultHub(address(verifier), oracle, genesis, epochLen, capital);
        vm.stopBroadcast();

        console.log("chainId      ", block.chainid);
        console.log("EpochVerifier", address(verifier));
        console.log("AgentVaultHub", address(hub));
        console.log("oracle       ", oracle);
        console.log("genesis      ", genesis);
        console.log("epochLength  ", epochLen);
    }
}
