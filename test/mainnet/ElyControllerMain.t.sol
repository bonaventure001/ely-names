// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ElyNamesMainnet} from "../../src/mainnet/ElyNamesMainnet.sol";
import {ElyControllerMain, INames, ILegacyController} from "../../src/mainnet/ElyControllerMain.sol";
import {MockToken} from "../ElyNames.t.sol";
import {TreeData} from "../TreeData.sol";

contract ElyControllerMainTest is Test {
    ElyNamesMainnet names;
    ElyControllerMain shop;
    MockToken partnerToken;
    address admin = address(0xA11CE);
    address treasury = address(0x7EA5);
    address alice = address(0xA1); // on the sample DEX list
    address bob = address(0xB0B);
    address carol = address(0xC4);
    address dave = address(0xD4);
    bytes32 secret = keccak256("s");

    function setUp() public {
        vm.warp(1_800_000_000);
        partnerToken = new MockToken();
        names = new ElyNamesMainnet(admin, treasury, 300);
        shop = new ElyControllerMain(INames(address(names)), ILegacyController(address(0)), treasury, admin, 5 ether, 0.3 ether, 0.2 ether, 0.1 ether);
        vm.prank(admin);
        names.setController(address(shop), true);
        string memory chars = "abcdefghijklmnopqrstuvwxyz0123456789";
        string[] memory r = new string[](36);
        for (uint256 i; i < 36; ++i) r[i] = string(abi.encodePacked(bytes(chars)[i]));
        vm.prank(admin);
        shop.setReserved(r, true);
        for (uint160 i = 0xA1; i <= 0xD4; i++) vm.deal(address(i), 1000 ether);
        vm.deal(bob, 1000 ether); // bob (0xB0B) is outside the range above
    }

    function _noProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _args(string memory label, address owner_, address referrer, uint256 programId, uint256 entryId, uint256 duration)
        internal
        view
        returns (ElyControllerMain.RegisterArgs memory)
    {
        return ElyControllerMain.RegisterArgs({
            label: label, owner: owner_, duration: duration, secret: secret, referrer: referrer, programId: programId, entryId: entryId
        });
    }

    function _register(address who, ElyControllerMain.RegisterArgs memory a, bytes32[] memory proof)
        internal
        returns (ElyControllerMain.Quote memory q)
    {
        bytes32 c = shop.makeCommitment(a.label, a.owner, a.secret);
        if (shop.commitments(c) == 0) { // a test may already have committed by hand
            vm.prank(who);
            shop.commit(c);
        }
        skip(20);
        (q,) = shop.quote(a, who, proof);
        vm.prank(who);
        shop.register{value: q.total}(a, proof);
    }

    function _plain(string memory label, address owner_, address referrer) internal view returns (ElyControllerMain.RegisterArgs memory) {
        return _args(label, owner_, referrer, 0, 0, 365 days);
    }

    function _makeReferrer(address who, string memory label) internal {
        _register(who, _args(label, who, address(0), 0, 0, 5 * 365 days), _noProof());
        uint256 id = names.idOf(label);
        vm.prank(who);
        names.setPrimaryName(id);
    }

    function test_priceTiers() public view {
        assertEq(shop.pricePerYear("a"), 5 ether);
        assertEq(shop.pricePerYear("ab"), 0.3 ether);
        assertEq(shop.pricePerYear("abc"), 0.3 ether);
        assertEq(shop.pricePerYear("abcd"), 0.2 ether);
        assertEq(shop.pricePerYear("abcdef"), 0.1 ether);
    }

    function test_singleLettersAreReservedAtLaunch() public {
        vm.prank(bob);
        shop.commit(shop.makeCommitment("a", bob, secret));
        skip(20);
        vm.prank(bob);
        vm.expectRevert(ElyControllerMain.NameReserved.selector);
        shop.register{value: 10 ether}(_plain("a", bob, address(0)), _noProof());
        // when the owner releases one it sells at the single-character price
        string[] memory l = new string[](1);
        l[0] = "a";
        vm.prank(admin);
        shop.setReserved(l, false);
        ElyControllerMain.Quote memory q = _register(bob, _plain("a", bob, address(0)), _noProof());
        assertEq(q.total, 5 ether);
        assertEq(names.ownerOf(names.idOf("a")), bob);
    }

    function test_premiumFollowsTheThirtyDayGrace() public {
        _register(carol, _plain("premname", carol, address(0)), _noProof());
        uint256 exp = names.nameExpires("premname");
        vm.warp(exp + 30 days - 1);
        assertFalse(names.available("premname"));
        vm.warp(exp + 30 days + 1);
        assertTrue(names.available("premname"));
        assertApproxEqAbs(shop.premiumFor("premname"), 2 ether, 0.001 ether);
        vm.warp(exp + 30 days + 7 days);
        assertApproxEqAbs(shop.premiumFor("premname"), 1 ether, 0.001 ether);
        vm.warp(exp + 30 days + 14 days);
        assertEq(shop.premiumFor("premname"), 0);
    }

    function test_graceBelongsToTheOwner() public {
        _register(carol, _plain("premname", carol, address(0)), _noProof());
        vm.warp(names.nameExpires("premname") + 20 days);
        vm.prank(bob);
        shop.commit(shop.makeCommitment("premname", bob, secret));
        skip(20);
        vm.prank(bob);
        vm.expectRevert(ElyNamesMainnet.NameUnavailable.selector);
        shop.register{value: 5 ether}(_plain("premname", bob, address(0)), _noProof());
        vm.prank(dave); // anyone may renew it for the owner at the normal price
        shop.renew{value: 0.1 ether}("premname", 365 days);
        assertEq(names.ownerOf(names.idOf("premname")), carol);
    }

    function test_referral_5and5_andPayout() public {
        _makeReferrer(dave, "daveprime");
        ElyControllerMain.Quote memory q = _register(bob, _plain("longname", bob, dave), _noProof());
        assertEq(q.discountBps, 500);
        assertEq(q.total, 0.095 ether);
        assertEq(q.reward, 0.00475 ether);
        assertEq(shop.referralOwed(dave), 0.00475 ether);
        vm.prank(admin);
        shop.withdraw();
        assertEq(address(shop).balance, 0.00475 ether); // owed money is untouched
        uint256 before = dave.balance;
        vm.prank(dave);
        shop.claimReferral();
        assertEq(dave.balance - before, 0.00475 ether);
        assertEq(address(shop).balance, 0);
    }

    function test_onlyTheBestDiscountApplies() public {
        _makeReferrer(dave, "daveprime");
        vm.prank(admin);
        shop.setPartner(address(partnerToken), 5000, 1);
        partnerToken.mint(bob, 1);
        ElyControllerMain.Quote memory q = _register(bob, _plain("longname", bob, dave), _noProof());
        assertEq(q.discountBps, 5000); // not 55%
    }

    function test_pauseStopsNewRegistrationsButNotRenewals() public {
        _register(carol, _plain("longname", carol, address(0)), _noProof());
        vm.prank(admin);
        shop.setPaused(true);
        vm.prank(bob);
        shop.commit(shop.makeCommitment("another1", bob, secret));
        skip(20);
        vm.prank(bob);
        vm.expectRevert(ElyControllerMain.RegistrationsPaused.selector);
        shop.register{value: 1 ether}(_plain("another1", bob, address(0)), _noProof());
        vm.prank(bob);
        shop.renew{value: 0.1 ether}("longname", 365 days); // renewals still work
        vm.prank(bob);
        vm.expectRevert();
        shop.setPaused(false); // only the owner can lift it
        vm.prank(admin);
        shop.setPaused(false);
        _register(bob, _plain("another1", bob, address(0)), _noProof());
    }

    function test_registerToAnotherWallet() public {
        _register(alice, _plain("giftname", bob, address(0)), _noProof());
        assertEq(names.ownerOf(names.idOf("giftname")), bob);
    }

    function test_programsWorkWithoutAPriorShop() public {
        vm.prank(admin);
        uint256 id = shop.createProgram(
            ElyControllerMain.ProgramInput({
                name: "Test", manager: address(0xFEED), root: TreeData.DEX_ROOT, discountBps: 2000, start: uint64(block.timestamp), end: 0,
                snapshotAt: uint64(block.timestamp), cap: 0, minLength: 0, checkLegacyKaola: true, listURI: "x"
            })
        );
        ElyControllerMain.Quote memory q = _register(alice, _args("longname", alice, address(0), id, 0, 365 days), TreeData.dexAlice());
        assertEq(q.total, 0.08 ether);
    }

    function test_settingsAndLimits() public {
        vm.startPrank(admin);
        shop.setPrices(10 ether, 1 ether, 0.5 ether, 0.2 ether);
        assertEq(shop.pricePerYear("a"), 10 ether);
        vm.expectRevert(ElyControllerMain.BadParam.selector);
        shop.setReferral(2501, 500);
        vm.expectRevert(ElyControllerMain.BadParam.selector);
        shop.setPremium(1 ether, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        shop.setPrices(0, 0, 0, 0);
    }

    function testFuzz_moneyAddsUp(uint8 yearsSeed, uint8 lenSeed, bool useReferrer) public {
        _makeReferrer(dave, "daveprime");
        uint256 dur = (uint256(yearsSeed % 10) + 1) * 365 days;
        string memory label = lenSeed % 3 == 0 ? "ab" : (lenSeed % 3 == 1 ? "abcd" : "abcdefg");
        ElyControllerMain.Quote memory q = _register(bob, _args(label, bob, useReferrer ? dave : address(0), 0, 0, dur), _noProof());
        assertLe(q.reward, (q.afterDiscount * 500) / 10_000);
        assertGe(address(shop).balance, shop.totalReferralOwed());
        vm.prank(admin);
        shop.withdraw();
        assertEq(address(shop).balance, shop.totalReferralOwed());
    }
}
