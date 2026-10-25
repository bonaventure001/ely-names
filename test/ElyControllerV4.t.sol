// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ElyNames} from "../src/ElyNames.sol";
import {ElyController} from "../src/ElyController.sol";
import {ElyControllerV4, ILegacyController} from "../src/ElyControllerV4.sol";
import {MockNFT, MockToken} from "./ElyNames.t.sol";
import {TreeData} from "./TreeData.sol";

contract ElyControllerV4Test is Test {
    ElyNames names;
    ElyController legacy;
    ElyControllerV4 v4;
    MockNFT kaola;
    MockToken partnerToken;

    address admin = address(0xA11CE);
    address treasury = address(0x7EA5);
    address partnerMgr = address(0xFEED);
    address alice = address(0xA1); // on the DEX / Kaola lists
    address bob = address(0xB0B); //  on the DEX / Kaola lists
    address carol = address(0xC4); // on the DEX / Kaola lists
    address dave = address(0xD4); //  not on any list
    address erin = address(0xE5); //  not on any list
    bytes32 secret = keccak256("s");

    uint256 constant P_LONG = 0.1 ether;

    function setUp() public {
        vm.warp(1_800_000_000);
        kaola = new MockNFT();
        partnerToken = new MockToken();
        names = new ElyNames(admin, treasury, 300);
        legacy = new ElyController(names, kaola, treasury, admin, 0.3 ether, 0.2 ether, P_LONG, 5);
        v4 = new ElyControllerV4(names, ILegacyController(address(legacy)), treasury, admin, 0.3 ether, 0.2 ether, P_LONG);
        vm.startPrank(admin);
        names.setController(address(legacy), true);
        names.setController(address(v4), true);
        vm.stopPrank();
        for (uint160 i = 0xA1; i <= 0xE5; i++) vm.deal(address(i), 1000 ether);
        vm.deal(bob, 1000 ether);
    }

    // ───────────── helpers ─────────────
    function _noProof() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function _args(string memory label, address owner_, address referrer, uint256 programId, uint256 entryId, uint256 duration)
        internal
        view
        returns (ElyControllerV4.RegisterArgs memory)
    {
        return ElyControllerV4.RegisterArgs({
            label: label, owner: owner_, duration: duration, secret: secret, referrer: referrer, programId: programId, entryId: entryId
        });
    }

    function _plain(string memory label, address owner_, address referrer)
        internal
        view
        returns (ElyControllerV4.RegisterArgs memory)
    {
        return _args(label, owner_, referrer, 0, 0, 365 days);
    }

    function _commit(address who, string memory label, address owner_) internal {
        vm.prank(who);
        v4.commit(v4.makeCommitment(label, owner_, secret));
        skip(20);
    }

    function _register(address who, ElyControllerV4.RegisterArgs memory a, bytes32[] memory proof)
        internal
        returns (ElyControllerV4.Quote memory q)
    {
        _commit(who, a.label, a.owner);
        (q,) = v4.quote(a, who, proof);
        vm.prank(who);
        v4.register{value: q.total}(a, proof);
    }

    /// a wallet with an active primary name (5 years) so it can be a referrer
    function _makeReferrer(address who, string memory label) internal {
        _register(who, _args(label, who, address(0), 0, 0, 5 * 365 days), _noProof());
        uint256 id = names.idOf(label); // look the id up first: a prank only covers the very next call
        vm.prank(who);
        names.setPrimaryName(id);
    }

    function _program(bytes32 root, uint16 bps, uint32 cap, uint8 minLen, bool legacyCheck, uint64 start) internal returns (uint256 id) {
        vm.prank(admin);
        id = v4.createProgram(
            ElyControllerV4.ProgramInput({
                name: "Test program", manager: partnerMgr, root: root, discountBps: bps, start: start, end: 0,
                snapshotAt: start, cap: cap, minLength: minLen, checkLegacyKaola: legacyCheck, listURI: "https://example.com/l.json"
            })
        );
    }

    // ───────────── referral maths ─────────────

    function test_referral_5percentOffAndReferrerEarns5percent() public {
        _makeReferrer(dave, "daveprime");
        ElyControllerV4.Quote memory q = _register(bob, _plain("longname", bob, dave), _noProof());
        assertEq(q.base, 0.1 ether);
        assertEq(q.discountBps, 500);
        assertEq(q.afterDiscount, 0.095 ether);
        assertEq(q.total, 0.095 ether);
        assertEq(q.reward, 0.00475 ether); // 5% of what the buyer paid
        assertEq(v4.referralOwed(dave), 0.00475 ether);
        assertEq(v4.totalReferralOwed(), 0.00475 ether);
        assertEq(names.ownerOf(names.idOf("longname")), bob);
    }

    function test_referral_threeYears_discountOnFirstYearOnly() public {
        _makeReferrer(dave, "daveprime");
        ElyControllerV4.Quote memory q = _register(bob, _args("longname", bob, dave, 0, 0, 3 * 365 days), _noProof());
        assertEq(q.base, 0.3 ether);
        assertEq(q.afterDiscount, 0.295 ether); // 0.3 minus 5% of ONE year
        assertEq(q.reward, 0.01475 ether);
    }

    function test_referral_referrerCanClaim_andOwnerCannotTakeIt() public {
        _makeReferrer(dave, "daveprime");
        _register(bob, _plain("longname", bob, dave), _noProof());
        uint256 owed = v4.referralOwed(dave);
        uint256 paid = 0.095 ether + P_LONG * 5; // bob's payment + dave's own 5-year registration
        assertEq(address(v4).balance, paid);

        vm.prank(admin);
        v4.withdraw(); // sends earnings only
        assertEq(treasury.balance, paid - owed);
        assertEq(address(v4).balance, owed);

        uint256 before = dave.balance;
        vm.prank(dave);
        v4.claimReferral();
        assertEq(dave.balance - before, owed);
        assertEq(address(v4).balance, 0);
        assertEq(v4.totalReferralOwed(), 0);

        vm.prank(dave);
        vm.expectRevert(ElyControllerV4.NothingToClaim.selector);
        v4.claimReferral();
    }

    function test_referral_ignoredWithoutAnActivePrimaryName() public {
        ElyControllerV4.Quote memory q = _register(bob, _plain("longname", bob, erin), _noProof()); // erin owns no name
        assertEq(q.discountBps, 0);
        assertEq(q.reward, 0);
        assertEq(v4.referralOwed(erin), 0);
    }

    function test_referral_ownsANameButNoPrimary_isIgnored() public {
        _register(erin, _plain("erinname", erin, address(0)), _noProof()); // has a name but never set it as primary
        ElyControllerV4.Quote memory q = _register(bob, _plain("longname", bob, erin), _noProof());
        assertEq(q.reward, 0);
    }

    function test_referral_selfReferralBlocked() public {
        _makeReferrer(dave, "daveprime");
        ElyControllerV4.Quote memory q = _register(dave, _plain("longname", dave, dave), _noProof()); // buyer = referrer
        assertEq(q.discountBps, 0);
        assertEq(q.reward, 0);
        ElyControllerV4.Quote memory q2 = _register(bob, _plain("longname2", dave, dave), _noProof()); // receiver = referrer
        assertEq(q2.discountBps, 0);
        assertEq(q2.reward, 0);
    }

    function test_referral_expiredPrimaryNoLongerCounts() public {
        _makeReferrer(dave, "daveprime");
        vm.warp(block.timestamp + 5 * 365 days + 1);
        ElyControllerV4.Quote memory q = _register(bob, _plain("longname", bob, dave), _noProof());
        assertEq(q.reward, 0);
        assertEq(q.discountBps, 0);
    }

    function test_referral_freeClaimPaysNothing() public {
        _makeReferrer(dave, "daveprime");
        uint256 id = _program(TreeData.KAOLA_ROOT, 10_000, 0, 5, false, uint64(block.timestamp));
        ElyControllerV4.Quote memory q =
            _register(alice, _args("alicehq", alice, dave, id, 1, 365 days), TreeData.kaolaAlice1());
        assertEq(q.total, 0);
        assertEq(q.reward, 0); // 5% of zero
        assertEq(v4.referralOwed(dave), 0);
    }

    function test_referral_renewalsEarnNothing() public {
        _makeReferrer(dave, "daveprime");
        uint256 before = v4.totalReferralOwed();
        vm.prank(bob);
        v4.renew{value: P_LONG}("daveprime", 365 days);
        assertEq(v4.totalReferralOwed(), before);
    }

    // ───────────── discounts never stack: the best one wins ─────────────

    function test_discounts_programBeatsReferral_noStacking() public {
        _makeReferrer(dave, "daveprime");
        uint256 id = _program(TreeData.DEX_ROOT, 2000, 0, 0, false, uint64(block.timestamp));
        ElyControllerV4.Quote memory q =
            _register(alice, _args("longname", alice, dave, id, 0, 365 days), TreeData.dexAlice());
        assertEq(q.discountBps, 2000); // 20%, NOT 25%
        assertEq(q.afterDiscount, 0.08 ether);
        assertEq(q.reward, 0.004 ether); // referrer still earns 5% of what was paid
    }

    function test_discounts_referralBeatsSmallerProgram() public {
        _makeReferrer(dave, "daveprime");
        uint256 id = _program(TreeData.DEX_ROOT, 200, 0, 0, false, uint64(block.timestamp)); // 2% program
        ElyControllerV4.Quote memory q =
            _register(alice, _args("longname", alice, dave, id, 0, 365 days), TreeData.dexAlice());
        assertEq(q.discountBps, 500); // the better one
        assertEq(v4.entryUsed(id, v4.leafOf(alice, 0)), true); // the entry is still used up
    }

    function test_discounts_holdingBeatsReferral() public {
        _makeReferrer(dave, "daveprime");
        vm.prank(admin);
        v4.setPartner(address(partnerToken), 5000, 1);
        partnerToken.mint(bob, 1);
        ElyControllerV4.Quote memory q = _register(bob, _plain("longname", bob, dave), _noProof());
        assertEq(q.discountBps, 5000);
        assertEq(q.afterDiscount, 0.05 ether);
    }

    // ───────────── expiry premium ─────────────

    function test_premium_schedule() public {
        _register(carol, _plain("premname", carol, address(0)), _noProof());
        uint256 exp = names.nameExpires("premname");
        uint256 g = names.GRACE_PERIOD();
        assertEq(v4.premiumFor("brandnewname"), 0); // never registered: no premium
        vm.warp(exp + g - 1);
        assertFalse(names.available("premname"));
        vm.warp(exp + g + 1);
        assertTrue(names.available("premname"));
        assertApproxEqAbs(v4.premiumFor("premname"), 2 ether, 0.001 ether);
        vm.warp(exp + g + 7 days);
        assertApproxEqAbs(v4.premiumFor("premname"), 1 ether, 0.001 ether);
        vm.warp(exp + g + 14 days);
        assertEq(v4.premiumFor("premname"), 0);
        vm.warp(exp + g + 40 days);
        assertEq(v4.premiumFor("premname"), 0);
    }

    function test_premium_originalOwnerKeepsPriorityDuringGrace() public {
        _register(carol, _plain("premname", carol, address(0)), _noProof());
        uint256 exp = names.nameExpires("premname");
        vm.warp(exp + 20 days); // inside the grace period
        _commit(bob, "premname", bob);
        vm.prank(bob);
        vm.expectRevert(ElyNames.NameUnavailable.selector); // nobody else can take it
        v4.register{value: 5 ether}(_plain("premname", bob, address(0)), _noProof());
        vm.prank(erin); // the owner (or anyone paying for them) can still renew at the normal price
        v4.renew{value: P_LONG}("premname", 365 days);
        assertEq(names.nameExpires("premname"), exp + 365 days);
        assertEq(names.ownerOf(names.idOf("premname")), carol);
    }

    function test_premium_isAddedAfterDiscount_andExcludedFromReward() public {
        _makeReferrer(dave, "daveprime");
        _register(carol, _plain("premname", carol, address(0)), _noProof());
        vm.warp(names.nameExpires("premname") + names.GRACE_PERIOD() + 7 days);
        ElyControllerV4.Quote memory q = _register(bob, _plain("premname", bob, dave), _noProof());
        assertEq(q.afterDiscount, 0.095 ether); // the 5% applies to the price only
        assertApproxEqAbs(q.premium, 1 ether, 0.01 ether); // the premium is never discounted
        assertEq(q.total, q.afterDiscount + q.premium);
        assertEq(q.reward, 0.00475 ether); // the premium earns the referrer nothing
        assertEq(names.ownerOf(names.idOf("premname")), bob);
    }

    function test_premium_overpaymentRefunded() public {
        _register(carol, _plain("premname", carol, address(0)), _noProof());
        vm.warp(names.nameExpires("premname") + names.GRACE_PERIOD() + 3 days);
        _commit(bob, "premname", bob);
        (ElyControllerV4.Quote memory q,) = v4.quote(_plain("premname", bob, address(0)), bob, _noProof());
        uint256 before = bob.balance;
        vm.prank(bob);
        v4.register{value: 50 ether}(_plain("premname", bob, address(0)), _noProof());
        assertEq(before - bob.balance, q.total);
    }

    function test_premium_settingsValidated() public {
        vm.startPrank(admin);
        v4.setPremium(1 ether, 7 days);
        assertEq(v4.premiumStart(), 1 ether);
        vm.expectRevert(ElyControllerV4.BadParam.selector);
        v4.setPremium(1 ether, 0);
        vm.expectRevert(ElyControllerV4.BadParam.selector);
        v4.setPremium(101 ether, 7 days);
        vm.expectRevert(ElyControllerV4.BadParam.selector);
        v4.setPremium(1 ether, 91 days);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        v4.setPremium(0, 1 days);
    }

    // ───────────── register to another wallet ─────────────

    function test_registerToAnotherWallet() public {
        _register(alice, _plain("giftname", bob, address(0)), _noProof()); // alice pays, bob receives
        assertEq(names.ownerOf(names.idOf("giftname")), bob);
        assertEq(names.balanceOf(alice), 0);
    }

    function test_registerToAnotherWallet_cannotBeRedirected() public {
        _commit(alice, "giftname", alice); // committed for herself...
        vm.prank(alice);
        vm.expectRevert(ElyControllerV4.CommitmentMissing.selector); // ...so it cannot be used to send the name to someone else
        v4.register{value: 1 ether}(_plain("giftname", bob, address(0)), _noProof());
    }

    // ───────────── settings ─────────────

    function test_referralSettings_boundsAndOwnerOnly() public {
        vm.startPrank(admin);
        v4.setReferral(1000, 300);
        assertEq(v4.referralRewardBps(), 1000);
        assertEq(v4.referralDiscountBps(), 300);
        vm.expectRevert(ElyControllerV4.BadParam.selector);
        v4.setReferral(2501, 300);
        vm.expectRevert(ElyControllerV4.BadParam.selector);
        v4.setReferral(300, 2501);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert();
        v4.setReferral(0, 0);
    }

    function test_referralDefaults() public view {
        assertEq(v4.referralRewardBps(), 500);
        assertEq(v4.referralDiscountBps(), 500);
        assertEq(v4.premiumStart(), 2 ether);
        assertEq(v4.premiumPeriod(), 14 days);
    }

    // ───────────── programs (carried over from V3) ─────────────

    function test_program_dexTwentyPercent() public {
        uint256 id = _program(TreeData.DEX_ROOT, 2000, 0, 0, false, uint64(block.timestamp));
        ElyControllerV4.Quote memory q = _register(alice, _args("longname", alice, address(0), id, 0, 365 days), TreeData.dexAlice());
        assertEq(q.total, 0.08 ether);
    }

    function test_program_notOnList_andProofBoundToSender() public {
        uint256 id = _program(TreeData.DEX_ROOT, 2000, 0, 0, false, uint64(block.timestamp));
        _commit(dave, "longname", dave);
        vm.prank(dave);
        vm.expectRevert(ElyControllerV4.NotEligible.selector);
        v4.register{value: 1 ether}(_args("longname", dave, address(0), id, 0, 365 days), TreeData.dexAlice());
        _commit(bob, "longname2", bob);
        vm.prank(bob);
        vm.expectRevert(ElyControllerV4.NotEligible.selector); // alice's proof does not work for bob
        v4.register{value: 1 ether}(_args("longname2", bob, address(0), id, 0, 365 days), TreeData.dexAlice());
    }

    function test_program_eachEntryOnce() public {
        uint256 id = _program(TreeData.DEX_ROOT, 2000, 0, 0, false, uint64(block.timestamp));
        _register(alice, _args("longname", alice, address(0), id, 0, 365 days), TreeData.dexAlice());
        _commit(alice, "second1", alice);
        vm.prank(alice);
        vm.expectRevert(ElyControllerV4.EntryAlreadyUsed.selector);
        v4.register{value: 1 ether}(_args("second1", alice, address(0), id, 0, 365 days), TreeData.dexAlice());
    }

    function test_program_kaolaSnapshot_freeAndLegacyRespected() public {
        uint256 id = _program(TreeData.KAOLA_ROOT, 10_000, 0, 5, true, uint64(block.timestamp));
        ElyControllerV4.Quote memory q = _register(alice, _args("alicehq", alice, address(0), id, 1, 365 days), TreeData.kaolaAlice1());
        assertEq(q.total, 0);
        // token 2 already claimed on the first controller: rejected
        kaola.mint(bob, 2);
        vm.prank(bob);
        legacy.commit(legacy.makeCommitment("bobhq1", bob, secret));
        skip(20);
        vm.prank(bob);
        legacy.claimFree("bobhq1", 2, secret);
        _commit(bob, "bobhq2", bob);
        vm.prank(bob);
        vm.expectRevert(ElyControllerV4.AlreadyClaimedOnLegacy.selector);
        v4.register(_args("bobhq2", bob, address(0), id, 2, 365 days), TreeData.kaolaBob2());
        // a snapshot outsider cannot claim
        _commit(dave, "davehq1", dave);
        vm.prank(dave);
        vm.expectRevert(ElyControllerV4.NotEligible.selector);
        v4.register(_args("davehq1", dave, address(0), id, 1, 365 days), TreeData.kaolaAlice1());
    }

    function test_program_capWindowAndRootLock() public {
        uint256 id = _program(TreeData.DEX_ROOT, 2000, 1, 0, false, uint64(block.timestamp));
        _register(alice, _args("longname", alice, address(0), id, 0, 365 days), TreeData.dexAlice());
        _commit(bob, "bobname1", bob);
        vm.prank(bob);
        vm.expectRevert(ElyControllerV4.ProgramCapReached.selector);
        v4.register{value: 1 ether}(_args("bobname1", bob, address(0), id, 0, 365 days), TreeData.dexBob());

        uint256 id2 = _program(bytes32(0), 2000, 0, 0, false, uint64(block.timestamp + 1 days));
        vm.prank(partnerMgr);
        v4.setProgramRoot(id2, TreeData.DEX_ROOT, "x");
        vm.warp(block.timestamp + 1 days);
        vm.prank(partnerMgr);
        vm.expectRevert(ElyControllerV4.RootLocked.selector);
        v4.setProgramRoot(id2, bytes32(uint256(1)), "x");
    }

    function test_reservedStillBlocked() public {
        string[] memory l = new string[](1);
        l[0] = "elysium";
        vm.prank(admin);
        v4.setReserved(l, true);
        _commit(bob, "elysium", bob);
        vm.prank(bob);
        vm.expectRevert(ElyControllerV4.NameReserved.selector);
        v4.register{value: 1 ether}(_plain("elysium", bob, address(0)), _noProof());
    }

    // ───────────── no name is ever wiped by the switch ─────────────

    function test_existingNamesSurviveSwitchingShops() public {
        vm.prank(alice);
        legacy.commit(legacy.makeCommitment("legacyname", alice, secret));
        skip(20);
        vm.prank(alice);
        legacy.register{value: P_LONG}("legacyname", alice, 365 days, secret);
        vm.prank(admin);
        names.setController(address(legacy), false);
        assertEq(names.resolve("legacyname"), alice);
        uint256 exp = names.nameExpires("legacyname");
        vm.prank(bob);
        v4.renew{value: P_LONG}("legacyname", 365 days);
        assertEq(names.nameExpires("legacyname"), exp + 365 days);
    }

    // ───────────── fuzz: the money always adds up ─────────────

    function testFuzz_referralAccounting(uint8 yearsSeed, uint8 lenSeed, bool useReferrer) public {
        _makeReferrer(dave, "daveprime");
        uint256 dur = (uint256(yearsSeed % 10) + 1) * 365 days;
        string memory label = lenSeed % 3 == 0 ? "ab" : (lenSeed % 3 == 1 ? "abcd" : "abcdefg");
        ElyControllerV4.Quote memory q = _register(bob, _args(label, bob, useReferrer ? dave : address(0), 0, 0, dur), _noProof());
        assertLe(q.reward, (q.afterDiscount * 500) / 10_000);
        assertLe(q.afterDiscount, q.base);
        assertGe(address(v4).balance, v4.totalReferralOwed());
        vm.prank(admin);
        v4.withdraw();
        assertEq(address(v4).balance, v4.totalReferralOwed());
    }
}
