// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ElyNamesMainnet} from "../../src/mainnet/ElyNamesMainnet.sol";
import {ElyControllerMain, INames, ILegacyController} from "../../src/mainnet/ElyControllerMain.sol";
import {ElyAuction, IAuctionNames} from "../../src/mainnet/ElyAuction.sol";

/// Deploys the whole mainnet package in one go: names, shop, auction, wiring, reserved names.
/// Env vars: OWNER (the wallet running this script), TREASURY (receives sales and royalties),
///           FINAL_OWNER (optional: a multisig; ownership of all three contracts is offered to it, and it must call acceptOwnership()).
contract DeployMainnet is Script {
    // PLACEHOLDER prices in HYPE per year. Change any time with setPrices on the shop.
    uint256 constant PRICE_SINGLE = 5 ether; // 1 character (reserved at launch; sold by auction first)
    uint256 constant PRICE_SHORT = 0.3 ether; // 2-3 characters
    uint256 constant PRICE_MID = 0.2 ether; //   4-5 characters
    uint256 constant PRICE_LONG = 0.1 ether; //  6+ characters

    function run() external {
        address owner = vm.envAddress("OWNER");
        address treasury = vm.envAddress("TREASURY");
        address finalOwner = vm.envOr("FINAL_OWNER", address(0));

        vm.startBroadcast();
        ElyNamesMainnet names = new ElyNamesMainnet(owner, treasury, 300); // 3% resale royalty
        ElyControllerMain shop = new ElyControllerMain(
            INames(address(names)), ILegacyController(address(0)), treasury, owner, PRICE_SINGLE, PRICE_SHORT, PRICE_MID, PRICE_LONG
        );
        ElyAuction auction = new ElyAuction(IAuctionNames(address(names)), treasury, owner);
        names.setController(address(shop), true);
        names.setController(address(auction), true);

        // reserved: brand names, plus all 36 single characters (a-z, 0-9) which are auctioned first
        string[] memory brands = new string[](14);
        brands[0] = "ely";
        brands[1] = "elysium";
        brands[2] = "kinetiq";
        brands[3] = "hyperliquid";
        brands[4] = "hyperevm";
        brands[5] = "hype";
        brands[6] = "kaola";
        brands[7] = "koala";
        brands[8] = "admin";
        brands[9] = "support";
        brands[10] = "official";
        brands[11] = "team";
        brands[12] = "bridge";
        brands[13] = "wallet";
        shop.setReserved(brands, true);
        bytes memory chars = "abcdefghijklmnopqrstuvwxyz0123456789";
        string[] memory singles = new string[](36);
        for (uint256 i; i < 36; ++i) singles[i] = string(abi.encodePacked(chars[i]));
        shop.setReserved(singles, true);

        if (finalOwner != address(0)) {
            names.transferOwnership(finalOwner);
            shop.transferOwnership(finalOwner);
            auction.transferOwnership(finalOwner);
        }
        vm.stopBroadcast();

        console.log("ElyNamesMainnet: ", address(names));
        console.log("ElyControllerMain:", address(shop));
        console.log("ElyAuction:       ", address(auction));
        if (finalOwner != address(0)) console.log("Ownership offered to:", finalOwner);
    }
}
