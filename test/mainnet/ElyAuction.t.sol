// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ElyNamesMainnet} from "../../src/mainnet/ElyNamesMainnet.sol";
import {ElyAuction, IAuctionNames} from "../../src/mainnet/ElyAuction.sol";

contract Griefer {
    function bid(ElyAuction a, string memory l) external payable {
        a.bid{value: msg.value}(l);
    }
    function pull(ElyAuction a) external {
        a.withdraw();
    }
    receive() external payable {
        revert("no refunds for me");
    }
}

contract Reenterer {
    ElyAuction public a;
    uint256 public received;
    bool entered;
    constructor(ElyAuction a_) {
        a = a_;
    }
    function bid(string memory l) external payable {
        a.bid{value: msg.value}(l);
    }
    function pull() external {
        a.withdraw();
    }
    receive() external payable {
        received += msg.value;
        if (!entered) {
            entered = true;
            try a.withdraw() {} catch {}
        }
    }
}

contract ElyAuctionTest is Test {
    ElyNamesMainnet names;
    ElyAuction auction;
    address admin = address(0xA11CE);
    address treasury = address(0x7EA5);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    address carol = address(0xC4);
    uint64 t0;
    uint64 constant D = 4 hours; //  one auction
    uint64 constant G = 40 minutes; // pause before the next one

    function setUp() public {
        vm.warp(1_800_000_000);
        names = new ElyNamesMainnet(admin, treasury, 300);
        auction = new ElyAuction(IAuctionNames(address(names)), treasury, admin);
        vm.startPrank(admin);
        names.setController(address(auction), true);
        names.setController(address(this), true); // lets one test pre-register a name
        vm.stopPrank();
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(carol, 1000 ether);
        t0 = uint64(block.timestamp + 1 hours);
    }

    function _sched(string memory a, string memory b, string memory c) internal {
        string[] memory l = new string[](3);
        l[0] = a;
        l[1] = b;
        l[2] = c;
        vm.prank(admin);
        auction.schedule(l, t0, D, G);
    }

    function _one(string memory label, uint64 start, uint64 dur) internal {
        string[] memory l = new string[](1);
        l[0] = label;
        vm.prank(admin);
        auction.schedule(l, start, dur, 0);
    }

    function _bid(address who, string memory label, uint256 amt) internal {
        vm.prank(who);
        auction.bid{value: amt}(label);
    }

    // ── scheduling ──
    function test_schedule_backToBack() public {
        _sched("a", "b", "c");
        assertEq(auction.auctionOf("a").start, t0);
        assertEq(auction.auctionOf("a").end, t0 + D);
        assertEq(auction.auctionOf("b").start, t0 + D + G); // 4 hours, then a 40 minute reset
        assertEq(auction.auctionOf("c").start, t0 + 2 * (D + G));
        (string[] memory labels,) = auction.getAuctions();
        assertEq(labels.length, 3);
    }

    function test_aWeekOfThirtySixAuctions() public {
        string memory chars = "abcdefghijklmnopqrstuvwxyz0123456789";
        string[] memory l = new string[](36);
        for (uint256 i; i < 36; ++i) l[i] = string(abi.encodePacked(bytes(chars)[i]));
        vm.prank(admin);
        auction.schedule(l, t0, D, G);
        assertEq(auction.auctionOf("a").start, t0);
        // the last auction ends 7 days minus the final reset after the first start
        assertEq(auction.auctionOf("9").end, t0 + 7 days - G);
        (string[] memory labels,) = auction.getAuctions();
        assertEq(labels.length, 36);
    }

    function test_schedule_validation() public {
        string[] memory l = new string[](1);
        l[0] = "a";
        vm.prank(alice);
        vm.expectRevert();
        auction.schedule(l, t0, 1 days, 0); // not the owner
        vm.startPrank(admin);
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.schedule(l, uint64(block.timestamp - 1), 1 days, 0); // starts in the past
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.schedule(l, t0, 10 minutes, 0); // too short
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.schedule(l, t0, 8 days, 0); // too long
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.schedule(l, t0, 1 days, 2 days); // gap too long
        l[0] = "abc";
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.schedule(l, t0, 1 days, 0); // only 1 and 2 character names
        l[0] = "";
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.schedule(l, t0, 1 days, 0);
        vm.stopPrank();
        string[] memory dup = new string[](2);
        dup[0] = "a";
        dup[1] = "a";
        vm.prank(admin);
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.schedule(dup, t0, 1 days, 0);
        names.register("q", alice, 365 days); // already registered elsewhere
        l[0] = "q";
        vm.prank(admin);
        vm.expectRevert(ElyAuction.LabelUnavailable.selector);
        auction.schedule(l, t0, 1 days, 0);
    }

    // ── bidding ──
    function test_bidRules() public {
        _sched("a", "b", "c");
        vm.expectRevert(ElyAuction.NotOpen.selector); // not started
        vm.prank(alice);
        auction.bid{value: 1 ether}("a");
        vm.warp(t0 + 1);
        vm.expectRevert(ElyAuction.BidTooLow.selector);
        vm.prank(alice);
        auction.bid{value: 0.99 ether}("a");
        _bid(alice, "a", 1 ether); // exactly the reserve
        assertEq(auction.minNextBid("a"), 1.05 ether); // +5%
        vm.expectRevert(ElyAuction.BidTooLow.selector);
        vm.prank(bob);
        auction.bid{value: 1.04 ether}("a");
        _bid(bob, "a", 1.05 ether);
        assertEq(auction.pendingReturns(alice), 1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        auction.withdraw();
        assertEq(alice.balance - before, 1 ether);
        vm.expectRevert(ElyAuction.NotOpen.selector); // the next auction has not started
        vm.prank(alice);
        auction.bid{value: 2 ether}("b");
        vm.warp(t0 + D);
        vm.expectRevert(ElyAuction.NotOpen.selector); // "a" is over
        vm.prank(carol);
        auction.bid{value: 9 ether}("a");
    }

    function test_noTimeExtension_lastSecondBidCanWin() public {
        _sched("a", "b", "c");
        uint64 end = auction.auctionOf("a").end;
        vm.warp(end - 1);
        _bid(alice, "a", 2 ether);
        assertEq(auction.auctionOf("a").end, end); // unchanged
        vm.warp(end);
        vm.expectRevert(ElyAuction.NotOpen.selector);
        vm.prank(bob);
        auction.bid{value: 50 ether}("a");
        auction.settle("a");
        assertEq(names.ownerOf(names.idOf("a")), alice);
    }

    // ── settling and money ──
    function test_settle_registersWinnerAndPaysTreasury() public {
        _sched("a", "b", "c");
        vm.warp(t0 + 1);
        _bid(alice, "a", 2 ether);
        _bid(bob, "a", 3 ether);
        vm.expectRevert(ElyAuction.NotEnded.selector);
        auction.settle("a");
        vm.warp(t0 + D);
        vm.prank(carol); // anyone can settle
        auction.settle("a");
        assertEq(names.ownerOf(names.idOf("a")), bob);
        assertEq(names.nameExpires("a"), block.timestamp + 365 days);
        assertEq(auction.proceeds(), 3 ether);
        vm.expectRevert(ElyAuction.AlreadySettled.selector);
        auction.settle("a");
        auction.sendProceeds();
        assertEq(treasury.balance, 3 ether);
        vm.prank(alice);
        auction.withdraw();
        assertEq(address(auction).balance, 0);
    }

    function test_noBids_staysUnsold_canBeScheduledAgain_orCancelled() public {
        _sched("a", "b", "c");
        vm.warp(t0 + D);
        auction.settle("a");
        assertTrue(auction.auctionOf("a").settled);
        assertTrue(names.available("a")); // not registered
        _one("a", uint64(block.timestamp + 1 hours), 1 days); // a second try
        assertFalse(auction.auctionOf("a").settled);
        vm.warp(block.timestamp + 2 hours);
        _bid(alice, "a", 2 ether);
        vm.prank(admin);
        vm.expectRevert(ElyAuction.HasBids.selector);
        auction.cancel("a");
        vm.prank(admin);
        auction.cancel("c"); // no bids, still scheduled
        vm.expectRevert(ElyAuction.NoSuchAuction.selector);
        vm.prank(alice);
        auction.bid{value: 2 ether}("c");
    }

    function test_registrationFails_winnerGetsMoneyBack() public {
        _sched("a", "b", "c");
        vm.warp(t0 + 1);
        _bid(alice, "a", 2 ether);
        names.register("a", carol, 365 days); // someone registers it by another route before the auction ends
        vm.warp(t0 + D);
        auction.settle("a");
        assertEq(names.ownerOf(names.idOf("a")), carol);
        assertEq(auction.pendingReturns(alice), 2 ether);
        assertEq(auction.proceeds(), 0);
        vm.prank(alice);
        auction.withdraw();
        assertEq(address(auction).balance, 0);
    }

    // ── hostile bidders ──
    function test_bidderWhoRefusesRefunds_cannotBlockOthers() public {
        _sched("a", "b", "c");
        vm.warp(t0 + 1);
        Griefer g = new Griefer();
        vm.deal(address(g), 10 ether);
        g.bid{value: 2 ether}(auction, "a");
        _bid(alice, "a", 2.1 ether); // outbids the griefer: not blocked
        assertEq(auction.pendingReturns(address(g)), 2 ether);
        vm.expectRevert(ElyAuction.TransferFailed.selector);
        g.pull(auction); // only the griefer is stuck
        _bid(bob, "a", 2.3 ether);
        vm.prank(alice);
        auction.withdraw(); // everyone else still gets paid
        assertEq(auction.pendingReturns(alice), 0);
    }

    function test_reentrantWithdraw_paysOnlyOnce() public {
        _sched("a", "b", "c");
        vm.warp(t0 + 1);
        Reenterer r = new Reenterer(auction);
        vm.deal(address(r), 10 ether);
        r.bid{value: 2 ether}("a");
        _bid(alice, "a", 2.1 ether);
        r.pull();
        assertEq(r.received(), 2 ether);
        assertEq(auction.pendingReturns(address(r)), 0);
        assertEq(address(auction).balance, 2.1 ether); // only the leading bid remains
    }

    // ── settings ──
    function test_settings() public {
        vm.startPrank(admin);
        auction.setSettings(3 ether, 1000, 730 days, address(0xBEEF));
        assertEq(auction.reserve(), 3 ether);
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.setSettings(1 ether, 2501, 365 days, treasury);
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.setSettings(1 ether, 500, 364 days, treasury);
        vm.expectRevert(ElyAuction.BadParam.selector);
        auction.setSettings(1 ether, 500, 365 days, address(0));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        auction.setSettings(0, 0, 365 days, treasury);
        assertEq(auction.reserve(), 3 ether);
    }

    function test_defaults() public view {
        assertEq(auction.reserve(), 1 ether);
        assertEq(auction.minRaiseBps(), 500);
        assertEq(auction.termDuration(), 365 days);
    }

    // ── the money always adds up ──
    function testFuzz_accounting(uint96 x, uint96 y, uint96 z) public {
        _sched("a", "b", "c");
        vm.warp(t0 + 1);
        uint256[3] memory amts = [uint256(x), uint256(y), uint256(z)];
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            vm.prank(who[i]);
            try auction.bid{value: amts[i] % 200 ether}("a") {} catch {}
        }
        uint256 owed = auction.pendingReturns(alice) + auction.pendingReturns(bob) + auction.pendingReturns(carol);
        assertEq(address(auction).balance, owed + auction.auctionOf("a").highBid);
    }
}
