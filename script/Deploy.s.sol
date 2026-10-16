// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ElyNames} from "../src/ElyNames.sol";
import {ElyController} from "../src/ElyController.sol";

/// Env vars required: OWNER (admin wallet), TREASURY (wallet that receives the money)
contract Deploy is Script {
    address constant KAOLA = 0xE99D7A5CB301f023849888D5F34a43bB7f39D841;

    // PLACEHOLDER prices in HYPE per year. Change any time with controller.setPrices(...).
    uint256 constant PRICE_SHORT = 0.3 ether; // 2-3 chars
    uint256 constant PRICE_MID = 0.2 ether; //   4-5 chars
    uint256 constant PRICE_LONG = 0.1 ether; //  6+ chars
    uint256 constant FREE_MIN_LENGTH = 5; // shortest name a Kaola holder can claim free (changeable)

    function run() external {
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");

        vm.startBroadcast();
        ElyNames names = new ElyNames(owner);
        ElyController controller = new ElyController(
            names, IERC721(KAOLA), treasury, owner, PRICE_SHORT, PRICE_MID, PRICE_LONG, FREE_MIN_LENGTH
        );
        vm.stopBroadcast();

        console.log("ElyNames:      ", address(names));
        console.log("ElyController: ", address(controller));
        console.log("NEXT STEP: from the OWNER wallet call names.setController(controller, true)");
    }
}
