// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VaultVerifier} from "../src/VaultVerifier.sol";
import {VaultHub} from "../src/VaultHub.sol";
import {NettingAttestor, IHub, INetVerifier} from "../src/NettingAttestor.sol";

/// Deploy the v2 vaults: verifier, hub, and a netting attestor bound to it.
///
///   USDC=0x... ZEN=0x... NET_VERIFIER=0x... forge script script/DeployVaults.s.sol \
///     --rpc-url horizen_testnet --broadcast --private-key $PK
///
/// On Horizen testnet USDC is ZENDEX's tUSDC and ZEN is WZEN, the wrapped ZEN
/// ZENDEX pairs every pool with.
contract DeployVaults is Script {
    function run() external {
        address oracle = vm.envOr("ORACLE", msg.sender);
        address treasury = vm.envOr("TREASURY", msg.sender);
        uint64 epochLen = uint64(vm.envOr("EPOCH_LEN", uint256(180)));
        uint64 genesis = uint64(vm.envOr("GENESIS", block.timestamp));
        uint256 minBond = vm.envOr("MIN_BOND", uint256(1e15)); // 0.001 ZEN
        uint256 perZen = vm.envOr("CAPACITY_PER_ZEN", uint256(1e13)); // 10,000,000 USDC per ZEN on testnet

        vm.startBroadcast();
        VaultVerifier verifier = new VaultVerifier();
        VaultHub hub = new VaultHub(
            address(verifier), oracle, genesis, epochLen, vm.envAddress("USDC"), vm.envAddress("ZEN"), treasury, minBond, perZen
        );
        NettingAttestor attestor = new NettingAttestor(IHub(address(hub)), INetVerifier(vm.envAddress("NET_VERIFIER")));
        vm.stopBroadcast();

        console.log("VaultVerifier  ", address(verifier));
        console.log("VaultHub       ", address(hub));
        console.log("NettingAttestor", address(attestor));
        console.log("genesis        ", genesis);
    }
}
