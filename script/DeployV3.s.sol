// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ElyNames} from "../src/ElyNames.sol";
import {ElyControllerV3, ILegacyController} from "../src/ElyControllerV3.sol";

/// Deploys the new controller next to the existing contracts. It does NOT touch any name.
/// Env vars: OWNER (must be the wallet running this, and the ElyNames owner), TREASURY,
///           NAMES (existing ElyNames address), LEGACY (old controller address, or 0x000...000 on a fresh mainnet).
contract DeployV3 is Script {
    // PLACEHOLDER prices in HYPE per year, same as before. Change any time with setPrices.
    uint256 constant PRICE_SHORT = 0.3 ether;
    uint256 constant PRICE_MID = 0.2 ether;
    uint256 constant PRICE_LONG = 0.1 ether;

    function run() external {
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        ElyNames names = ElyNames(vm.envAddress("NAMES"));
        address legacy = vm.envAddress("LEGACY");

        vm.startBroadcast();
        ElyControllerV3 v3 =
            new ElyControllerV3(names, ILegacyController(legacy), treasury, owner, PRICE_SHORT, PRICE_MID, PRICE_LONG);
        names.setController(address(v3), true); // allow the new controller; the old one keeps working until you switch it off

        string[] memory r = new string[](14);
        r[0] = "ely";
        r[1] = "elysium";
        r[2] = "kinetiq";
        r[3] = "hyperliquid";
        r[4] = "hyperevm";
        r[5] = "hype";
        r[6] = "kaola";
        r[7] = "koala";
        r[8] = "admin";
        r[9] = "support";
        r[10] = "official";
        r[11] = "team";
        r[12] = "bridge";
        r[13] = "wallet";
        v3.setReserved(r, true);
        vm.stopBroadcast();

        console.log("ElyControllerV3:", address(v3));
        console.log("Authorized on ElyNames and reserved names set. Old controller still active.");
    }
}
