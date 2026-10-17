// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ElyNames} from "../src/ElyNames.sol";
import {ElyController} from "../src/ElyController.sol";

/// Env vars required: OWNER (must be the same wallet that runs this script), TREASURY (receives sales + royalties)
contract Deploy is Script {
    address constant KAOLA = 0xE99D7A5CB301f023849888D5F34a43bB7f39D841;

    // PLACEHOLDER prices in HYPE per year. Change any time with controller.setPrices(...).
    uint256 constant PRICE_SHORT = 0.3 ether; // 2-3 chars
    uint256 constant PRICE_MID = 0.2 ether; //   4-5 chars
    uint256 constant PRICE_LONG = 0.1 ether; //  6+ chars
    uint256 constant FREE_MIN_LENGTH = 5; // shortest name a Kaola holder can claim free (changeable)
    uint96 constant ROYALTY_BPS = 300; // 3% resale royalty (changeable, max 10%)

    function run() external {
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast();
        ElyNames names = new ElyNames(owner, treasury, ROYALTY_BPS);
        ElyController controller = new ElyController(
            names, IERC721(KAOLA), treasury, owner, PRICE_SHORT, PRICE_MID, PRICE_LONG, FREE_MIN_LENGTH
        );
        names.setController(address(controller), true);

        // Protected names: the public cannot register these. Edit this list before mainnet.
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
        controller.setReserved(r, true);
        vm.stopBroadcast();

        console.log("ElyNames:      ", address(names));
        console.log("ElyController: ", address(controller));
        console.log("Controller already authorized and reserved names set.");
    }
}
