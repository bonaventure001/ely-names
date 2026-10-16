// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ElyNames} from "../src/ElyNames.sol";
import {ElyController} from "../src/ElyController.sol";

contract MockNFT is ERC721 {
    constructor() ERC721("Mock", "MCK") {}
    function mint(address to, uint256 id) external { _mint(to, id); }
}

contract MockToken is ERC20 {
    constructor() ERC20("Tok", "TOK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

contract ElyNamesTest is Test {
    ElyNames names;
    ElyController ctrl;
    MockNFT kaola;
    MockNFT partnerNft;
    MockToken partnerToken;

    address admin = address(0xA11CE);
    address treasury = address(0x7EA5);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    bytes32 secret = keccak256("s");

    uint256 constant P_SHORT = 0.3 ether;
    uint256 constant P_MID = 0.2 ether;
    uint256 constant P_LONG = 0.1 ether;

    function setUp() public {
        vm.warp(1_800_000_000);
        kaola = new MockNFT();
        partnerNft = new MockNFT();
        partnerToken = new MockToken();
        names = new ElyNames(admin);
        ctrl = new ElyController(names, kaola, treasury, admin, P_SHORT, P_MID, P_LONG, 5);
        vm.prank(admin);
        names.setController(address(ctrl), true);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // helper: commit, wait, then return so the caller can reveal
    function _commit(address who, string memory label, address owner) internal {
        vm.prank(who);
        ctrl.commit(ctrl.makeCommitment(label, owner, secret));
        skip(20);
    }

    function _buy(address who, string memory label, uint256 duration) internal {
        _commit(who, label, who);
        (uint256 price,) = ctrl.registerPrice(label, duration, who);
        vm.prank(who);
        ctrl.register{value: price}(label, who, duration, secret);
    }

    // ─────────── free Kaola claim ───────────

    function test_freeClaim() public {
        kaola.mint(alice, 1);
        _commit(alice, "alicehq", alice);
        vm.prank(alice);
        ctrl.claimFree("alicehq", 1, secret);
        assertEq(names.ownerOf(names.idOf("alicehq")), alice);
        assertEq(names.nameExpires("alicehq"), block.timestamp + 365 days);
        assertEq(names.resolve("alicehq"), alice);
    }

    function test_freeClaim_onlyOncePerId_evenAfterSale() public {
        kaola.mint(alice, 1);
        _commit(alice, "alicehq", alice);
        vm.prank(alice);
        ctrl.claimFree("alicehq", 1, secret);

        vm.prank(alice);
        kaola.transferFrom(alice, bob, 1); // NFT sold
        _commit(bob, "bobhq1", bob);
        vm.prank(bob);
        vm.expectRevert(ElyController.KaolaAlreadyClaimed.selector);
        ctrl.claimFree("bobhq1", 1, secret);
    }

    function test_freeClaim_newOwnerCanClaimOtherIds() public {
        kaola.mint(alice, 1);
        kaola.mint(alice, 2);
        _commit(alice, "first1", alice);
        vm.prank(alice);
        ctrl.claimFree("first1", 1, secret);
        // second id, second name
        vm.prank(alice);
        ctrl.commit(ctrl.makeCommitment("second", alice, secret));
        skip(20);
        vm.prank(alice);
        ctrl.claimFree("second", 2, secret);
        assertEq(names.balanceOf(alice), 2);
    }

    function test_freeClaim_notHolder() public {
        kaola.mint(alice, 1);
        _commit(bob, "bobhq1", bob);
        vm.prank(bob);
        vm.expectRevert(ElyController.NotKaolaOwner.selector);
        ctrl.claimFree("bobhq1", 1, secret);
    }

    function test_freeClaim_minLength() public {
        kaola.mint(alice, 1);
        _commit(alice, "abcd", alice);
        vm.prank(alice);
        vm.expectRevert(ElyController.NameTooShortForFreeClaim.selector);
        ctrl.claimFree("abcd", 1, secret);
    }

    function test_freeClaim_canBeClosed() public {
        kaola.mint(alice, 1);
        vm.prank(admin);
        ctrl.setFreeClaimOpen(false);
        _commit(alice, "alicehq", alice);
        vm.prank(alice);
        vm.expectRevert(ElyController.FreeClaimClosed.selector);
        ctrl.claimFree("alicehq", 1, secret);
    }

    // ─────────── pricing + paid registration ───────────

    function test_priceTiers() public view {
        assertEq(ctrl.pricePerYear("ab"), P_SHORT);
        assertEq(ctrl.pricePerYear("abc"), P_SHORT);
        assertEq(ctrl.pricePerYear("abcd"), P_MID);
        assertEq(ctrl.pricePerYear("abcde"), P_MID);
        assertEq(ctrl.pricePerYear("abcdef"), P_LONG);
    }

    function test_register_refundsExcess() public {
        _commit(alice, "longname", alice);
        uint256 before = alice.balance;
        vm.prank(alice);
        ctrl.register{value: 5 ether}("longname", alice, 365 days, secret);
        assertEq(before - alice.balance, P_LONG);
        assertEq(address(ctrl).balance, P_LONG);
    }

    function test_register_underpaid() public {
        _commit(alice, "longname", alice);
        vm.prank(alice);
        vm.expectRevert(ElyController.InsufficientPayment.selector);
        ctrl.register{value: P_LONG - 1}("longname", alice, 365 days, secret);
    }

    function test_pricesChangeWithoutRedeploy() public {
        vm.prank(admin);
        ctrl.setPrices(1 ether, 0.5 ether, 0.05 ether);
        assertEq(ctrl.pricePerYear("longname"), 0.05 ether);
        (uint256 p,) = ctrl.registerPrice("longname", 2 * 365 days, alice);
        assertEq(p, 0.1 ether);
    }

    function test_onlyOwnerCanSetPrices() public {
        vm.prank(alice);
        vm.expectRevert();
        ctrl.setPrices(0, 0, 0);
    }

    // ─────────── commit-reveal ───────────

    function test_reveal_withoutCommit() public {
        vm.prank(alice);
        vm.expectRevert(ElyController.CommitmentMissing.selector);
        ctrl.register{value: 1 ether}("longname", alice, 365 days, secret);
    }

    function test_reveal_tooSoon() public {
        vm.prank(alice);
        ctrl.commit(ctrl.makeCommitment("longname", alice, secret));
        vm.prank(alice);
        vm.expectRevert(ElyController.CommitmentTooNew.selector);
        ctrl.register{value: 1 ether}("longname", alice, 365 days, secret);
    }

    function test_reveal_expiredCommitment() public {
        vm.prank(alice);
        ctrl.commit(ctrl.makeCommitment("longname", alice, secret));
        skip(25 hours);
        vm.prank(alice);
        vm.expectRevert(ElyController.CommitmentExpired.selector);
        ctrl.register{value: 1 ether}("longname", alice, 365 days, secret);
    }

    // ─────────── partner discounts ───────────

    function test_partnerDiscount_firstYearOnly() public {
        vm.prank(admin);
        ctrl.setPartner(address(partnerNft), 5000, 1); // 50% off first year
        partnerNft.mint(alice, 1);

        (uint256 p1, uint16 bps) = ctrl.registerPrice("longname", 365 days, alice);
        assertEq(bps, 5000);
        assertEq(p1, P_LONG / 2);

        // 3 years: only the first year is discounted
        (uint256 p3,) = ctrl.registerPrice("longname", 3 * 365 days, alice);
        assertEq(p3, 3 * P_LONG - P_LONG / 2);

        // non-holder pays full price
        (uint256 pb, uint16 bpsB) = ctrl.registerPrice("longname", 365 days, bob);
        assertEq(bpsB, 0);
        assertEq(pb, P_LONG);
    }

    function test_partnerDiscount_takesBestOfSeveral() public {
        vm.startPrank(admin);
        ctrl.setPartner(address(partnerNft), 2000, 1);
        ctrl.setPartner(address(partnerToken), 7000, 100 ether); // DeFi token, needs 100 tokens
        vm.stopPrank();
        partnerNft.mint(alice, 1);
        partnerToken.mint(alice, 50 ether); // below threshold
        assertEq(ctrl.discountBpsOf(alice), 2000);
        partnerToken.mint(alice, 50 ether);
        assertEq(ctrl.discountBpsOf(alice), 7000);
    }

    function test_partnerDiscount_disable() public {
        vm.startPrank(admin);
        ctrl.setPartner(address(partnerNft), 5000, 1);
        ctrl.setPartner(address(partnerNft), 0, 1);
        vm.stopPrank();
        partnerNft.mint(alice, 1);
        assertEq(ctrl.discountBpsOf(alice), 0);
    }

    function test_partnerDiscount_brokenContractDoesNotBlock() public {
        vm.prank(admin);
        ctrl.setPartner(address(this), 5000, 1); // this test contract has no balanceOf
        assertEq(ctrl.discountBpsOf(alice), 0);
        _buy(alice, "longname", 365 days); // still registers fine
    }

    // ─────────── renewals, expiry, grace ───────────

    function test_renew_fullPrice_noDiscount() public {
        vm.prank(admin);
        ctrl.setPartner(address(partnerNft), 5000, 1);
        partnerNft.mint(alice, 1);
        _buy(alice, "longname", 365 days);
        uint256 exp = names.nameExpires("longname");
        vm.prank(alice);
        ctrl.renew{value: P_LONG}("longname", 365 days);
        assertEq(names.nameExpires("longname"), exp + 365 days);
    }

    function test_renew_duringGrace_ok_afterGrace_fails() public {
        _buy(alice, "longname", 365 days);
        vm.warp(names.nameExpires("longname") + 30 days);
        vm.prank(alice);
        ctrl.renew{value: P_LONG}("longname", 365 days);

        vm.warp(names.nameExpires("longname") + 91 days);
        vm.prank(alice);
        vm.expectRevert(ElyNames.TooLateToRenew.selector);
        ctrl.renew{value: P_LONG}("longname", 365 days);
    }

    function test_expiry_ownerOfReverts_andResolveEmpty() public {
        _buy(alice, "longname", 365 days);
        uint256 id = names.idOf("longname");
        vm.warp(names.nameExpires("longname") + 1);
        vm.expectRevert(ElyNames.NameExpired.selector);
        names.ownerOf(id);
        assertEq(names.resolve("longname"), address(0));
        assertEq(names.primaryNameOf(alice), "");
    }

    function test_expiredName_cannotBeTransferred() public {
        _buy(alice, "longname", 365 days);
        uint256 id = names.idOf("longname");
        vm.warp(names.nameExpires("longname") + 1);
        vm.prank(alice);
        vm.expectRevert(ElyNames.NameExpired.selector);
        names.transferFrom(alice, bob, id);
    }

    function test_available_afterGrace_andReRegister() public {
        _buy(alice, "longname", 365 days);
        assertFalse(names.available("longname"));
        vm.warp(names.nameExpires("longname") + 89 days);
        assertFalse(names.available("longname"));
        vm.warp(names.nameExpires("longname") + 91 days);
        assertTrue(names.available("longname"));

        _buy(bob, "longname", 365 days);
        assertEq(names.ownerOf(names.idOf("longname")), bob);
        assertEq(names.resolve("longname"), bob);
    }

    function test_cannotRegisterTakenName() public {
        _buy(alice, "longname", 365 days);
        _commit(bob, "longname", bob);
        vm.prank(bob);
        vm.expectRevert(ElyNames.NameUnavailable.selector);
        ctrl.register{value: P_LONG}("longname", bob, 365 days, secret);
    }

    // ─────────── records + primary name ───────────

    function test_records_setAndRead() public {
        _buy(alice, "longname", 365 days);
        uint256 id = names.idOf("longname");
        vm.startPrank(alice);
        names.setAddr(id, bob);
        names.setText(id, "com.twitter", "alice_x");
        vm.stopPrank();
        assertEq(names.resolve("longname"), bob);
        assertEq(names.text("longname", "com.twitter"), "alice_x");
    }

    function test_records_onlyOwner() public {
        _buy(alice, "longname", 365 days);
        uint256 id = names.idOf("longname");
        vm.prank(bob);
        vm.expectRevert(ElyNames.NotNameOwner.selector);
        names.setAddr(id, bob);
    }

    function test_records_resetOnTransfer() public {
        _buy(alice, "longname", 365 days);
        uint256 id = names.idOf("longname");
        vm.startPrank(alice);
        names.setText(id, "k", "v");
        names.transferFrom(alice, bob, id);
        vm.stopPrank();
        assertEq(names.resolve("longname"), bob);
        assertEq(names.text("longname", "k"), "");
    }

    function test_primaryName() public {
        _buy(alice, "longname", 365 days);
        uint256 id = names.idOf("longname");
        vm.prank(alice);
        names.setPrimaryName(id);
        assertEq(names.primaryNameOf(alice), "longname.ely");
        vm.prank(alice);
        names.transferFrom(alice, bob, id);
        assertEq(names.primaryNameOf(alice), ""); // no longer owner
    }

    function test_primaryName_notOwner() public {
        _buy(alice, "longname", 365 days);
        uint256 id = names.idOf("longname");
        vm.prank(bob);
        vm.expectRevert(ElyNames.NotNameOwner.selector);
        names.setPrimaryName(id);
    }

    // ─────────── label validation ───────────

    function test_labelValidation() public view {
        assertTrue(names.isValidLabel("ab"));
        assertTrue(names.isValidLabel("a-b-1"));
        assertFalse(names.isValidLabel("a")); // too short
        assertFalse(names.isValidLabel("Ab")); // uppercase
        assertFalse(names.isValidLabel("-ab"));
        assertFalse(names.isValidLabel("ab-"));
        assertFalse(names.isValidLabel("a b"));
        assertFalse(names.isValidLabel(unicode"aé")); // non-ASCII
        assertFalse(names.isValidLabel("a.b"));
    }

    function test_register_invalidLabel() public {
        _commit(alice, "Bad", alice);
        vm.prank(alice);
        vm.expectRevert(ElyNames.InvalidLabel.selector);
        ctrl.register{value: 1 ether}("Bad", alice, 365 days, secret);
    }

    function test_onlyControllerCanRegister() public {
        vm.prank(alice);
        vm.expectRevert(ElyNames.NotController.selector);
        names.register("hacker", alice, 365 days);
    }

    // ─────────── treasury ───────────

    function test_withdrawToTreasury() public {
        _buy(alice, "longname", 365 days);
        vm.prank(admin);
        ctrl.withdraw();
        assertEq(treasury.balance, P_LONG);
        assertEq(address(ctrl).balance, 0);
    }

    function test_withdraw_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        ctrl.withdraw();
    }

    function test_tokenURI_works() public {
        _buy(alice, "longname", 365 days);
        string memory uri = names.tokenURI(names.idOf("longname"));
        assertGt(bytes(uri).length, 100);
    }
}
