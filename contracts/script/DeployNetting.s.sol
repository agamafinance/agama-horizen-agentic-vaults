// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {NetVerifier} from "../src/NetVerifier.sol";
import {NettingAttestor, IHub, INetVerifier} from "../src/NettingAttestor.sol";

/// Deploy the netting verifier and the attestor next to an existing hub.
///
///   HUB=0x... forge script script/DeployNetting.s.sol \
///     --rpc-url horizen_testnet --broadcast --private-key $PK
contract DeployNetting is Script {
    function run() external {
        address hub = vm.envAddress("HUB");

        vm.startBroadcast();
        NetVerifier verifier = new NetVerifier();
        NettingAttestor attestor = new NettingAttestor(IHub(hub), INetVerifier(address(verifier)));
        vm.stopBroadcast();

        console.log("chainId        ", block.chainid);
        console.log("NetVerifier    ", address(verifier));
        console.log("NettingAttestor", address(attestor));
        console.log("hub            ", hub);
    }
}
