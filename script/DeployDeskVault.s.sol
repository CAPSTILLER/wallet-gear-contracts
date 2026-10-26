// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Script.sol";
import {DeskVault} from "../src/DeskVault.sol";

/// Deploys DeskVault on Base owned directly by Cap's Ledger (no handoff needed).
/// forge script script/DeployDeskVault.s.sol:DeployDeskVault --rpc-url base --broadcast --verify
contract DeployDeskVault is Script {
    address constant LEDGER = 0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca;
    address constant GEAR = 0x5880cD05605A549f1DAb01a53ca61Ee559244bD1;

    function run() external returns (DeskVault v) {
        vm.startBroadcast();
        v = new DeskVault(LEDGER, GEAR);
        vm.stopBroadcast();
        console.log("DeskVault", address(v));
    }
}
