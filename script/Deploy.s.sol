// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Script.sol";
import {WalletGear} from "../src/WalletGear.sol";
import {GearTradeDesk} from "../src/GearTradeDesk.sol";

/// Deploys both contracts with the deployer as temporary owner, then starts the
/// Ownable2Step handoff to Cap's Ledger (Ledger must call acceptOwnership on each).
contract Deploy is Script {
    address constant LEDGER = 0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913; // Base USDC (6 dec)
    address constant GEAR = 0x5880cD05605A549f1DAb01a53ca61Ee559244bD1; // Base GEAR (6 dec)
    address constant VAULT = 0x41ca72E18f7F96F8F2b7be524AC8346e06bCB3AB;
    address constant TREASURY = 0xCF1ac98565DA846E8263604b49C1276Ed78A0981;

    function run() external {
        string memory baseURI = vm.envOr("BASE_URI", string(""));
        vm.startBroadcast();
        WalletGear g = new WalletGear(msg.sender, USDC, TREASURY, 1_000_000, baseURI);
        GearTradeDesk d = new GearTradeDesk(msg.sender, address(g), GEAR, VAULT, TREASURY);
        g.transferOwnership(LEDGER);
        d.transferOwnership(LEDGER);
        vm.stopBroadcast();
        console.log("WalletGear", address(g));
        console.log("GearTradeDesk", address(d));
    }
}
