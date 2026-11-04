// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ElyNamesMainnet} from "../../src/mainnet/ElyNamesMainnet.sol";

contract ElyNamesMainnetTest is Test {
    ElyNamesMainnet names;
    address admin = address(0xA11CE);
    address treasury = address(0x7EA5);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    address hot = address(0xFEED); // an everyday wallet appointed as manager
    address operator = address(0x0B0E);

    function setUp() public {
        vm.warp(1_800_000_000);
        names = new ElyNamesMainnet(admin, treasury, 300);
        vm.prank(admin);
        names.setController(address(this), true); // the test acts as the shop
    }

    function _id(string memory l) internal view returns (uint256) {
        return names.idOf(l);
    }

    // ── single characters and the 30-day grace ──
    function test_singleCharacterNames() public {
        assertTrue(names.isValidLabel("a"));
        assertTrue(names.isValidLabel("z"));
        assertTrue(names.isValidLabel("0"));
        assertTrue(names.isValidLabel("9"));
        assertFalse(names.isValidLabel("-")); // a lone hyphen is not a name
        assertFalse(names.isValidLabel(""));
        assertFalse(names.isValidLabel("A"));
        assertFalse(names.isValidLabel(unicode"é"));
        names.register("a", alice, 365 days);
        names.register("0", alice, 365 days);
        assertEq(names.ownerOf(_id("a")), alice);
        assertGt(bytes(names.tokenURI(_id("a"))).length, 100);
    }

    function test_graceIsThirtyDays() public {
        assertEq(names.GRACE_PERIOD(), 30 days);
        names.register("abc", alice, 365 days);
        uint256 exp = names.nameExpires("abc");
        vm.warp(exp + 30 days - 1);
        assertFalse(names.available("abc"));
        vm.warp(exp + 30 days + 1);
        assertTrue(names.available("abc"));
    }

    function test_renewOnlyDuringGrace() public {
        names.register("abc", alice, 365 days);
        uint256 exp = names.nameExpires("abc");
        vm.warp(exp + 29 days);
        names.renew("abc", 365 days);
        assertEq(names.nameExpires("abc"), exp + 365 days);
        vm.warp(exp + 365 days + 31 days);
        vm.expectRevert(ElyNamesMainnet.TooLateToRenew.selector);
        names.renew("abc", 365 days);
    }

    // ── owner and manager ──
    function test_managerCanEditRecords() public {
        names.register("abc", alice, 365 days);
        uint256 id = _id("abc");
        vm.prank(alice);
        names.setManager(id, hot);
        assertEq(names.managerOf(id), hot);
        vm.startPrank(hot);
        names.setAddr(id, bob);
        names.setText(id, "k", "v");
        vm.stopPrank();
        assertEq(names.resolve("abc"), bob);
        assertEq(names.text("abc", "k"), "v");
        assertEq(names.ownerOf(id), alice); // still hers
    }

    function test_managerCannotTakeTheName() public {
        names.register("abc", alice, 365 days);
        uint256 id = _id("abc");
        vm.prank(alice);
        names.setManager(id, hot);
        vm.prank(hot);
        vm.expectRevert(); // no transfer rights
        names.transferFrom(alice, hot, id);
        vm.prank(hot);
        vm.expectRevert(ElyNamesMainnet.NotNameOwner.selector); // cannot appoint anyone
        names.setManager(id, bob);
        vm.prank(hot);
        vm.expectRevert(ElyNamesMainnet.NotNameOwner.selector); // cannot claim it as its own primary name
        names.setPrimaryName(id);
        assertEq(names.ownerOf(id), alice);
    }

    function test_strangerCannotEdit() public {
        names.register("abc", alice, 365 days);
        uint256 id = _id("abc");
        vm.prank(bob);
        vm.expectRevert(ElyNamesMainnet.NotNameOwner.selector);
        names.setAddr(id, bob);
    }

    function test_managerClearedOnTransfer() public {
        names.register("abc", alice, 365 days);
        uint256 id = _id("abc");
        vm.startPrank(alice);
        names.setManager(id, hot);
        names.transferFrom(alice, bob, id);
        vm.stopPrank();
        assertEq(names.managerOf(id), address(0));
        vm.prank(hot);
        vm.expectRevert(ElyNamesMainnet.NotNameOwner.selector);
        names.setAddr(id, hot);
        vm.prank(bob);
        names.setAddr(id, bob);
        assertEq(names.resolve("abc"), bob);
    }

    function test_ownerCanRemoveManager() public {
        names.register("abc", alice, 365 days);
        uint256 id = _id("abc");
        vm.startPrank(alice);
        names.setManager(id, hot);
        names.setManager(id, address(0));
        vm.stopPrank();
        vm.prank(hot);
        vm.expectRevert(ElyNamesMainnet.NotNameOwner.selector);
        names.setAddr(id, hot);
    }

    function test_expiredNameHasNoManagerActions() public {
        names.register("abc", alice, 365 days);
        uint256 id = _id("abc");
        vm.prank(alice);
        names.setManager(id, hot);
        vm.warp(names.nameExpires("abc") + 1);
        assertEq(names.managerOf(id), address(0));
        vm.prank(hot);
        vm.expectRevert(ElyNamesMainnet.NameExpired.selector);
        names.setAddr(id, hot);
    }

    function test_approvedOperatorBehavesLikeTheOwner() public {
        names.register("abc", alice, 365 days);
        uint256 id = _id("abc");
        vm.prank(alice);
        names.approve(operator, id);
        vm.prank(operator);
        names.setManager(id, hot); // an operator who could transfer it anyway can also appoint a manager
        assertEq(names.managerOf(id), hot);
    }

    // ── what stayed the same ──
    function test_royaltyAndRecordsReset() public {
        names.register("abc", alice, 365 days);
        (address r, uint256 a) = names.royaltyInfo(_id("abc"), 10 ether);
        assertEq(r, treasury);
        assertEq(a, 0.3 ether);
        uint256 id = _id("abc");
        vm.prank(alice);
        names.setText(id, "k", "v");
        vm.prank(alice);
        names.transferFrom(alice, bob, id);
        assertEq(names.text("abc", "k"), "");
        assertEq(names.resolve("abc"), bob);
    }
}
