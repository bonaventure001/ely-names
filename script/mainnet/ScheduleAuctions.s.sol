// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ElyAuction} from "../../src/mainnet/ElyAuction.sol";

/// Schedules the 36 single-character auctions: 4 hours each, 40 minutes between them = exactly 7 days.
/// Env vars: AUCTION (the auction contract), FIRST_START (unix time the first auction opens; must be in the future).
/// Must be run by the auction's owner.
contract ScheduleAuctions is Script {
    function run() external {
        ElyAuction auction = ElyAuction(vm.envAddress("AUCTION"));
        uint64 firstStart = uint64(vm.envUint("FIRST_START"));
        bytes memory chars = "abcdefghijklmnopqrstuvwxyz0123456789";
        string[] memory labels = new string[](36);
        for (uint256 i; i < 36; ++i) labels[i] = string(abi.encodePacked(chars[i]));
        vm.startBroadcast();
        auction.schedule(labels, firstStart, 4 hours, 40 minutes);
        vm.stopBroadcast();
        console.log("Scheduled 36 auctions starting at", firstStart);
    }
}
