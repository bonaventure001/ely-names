// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ElyNames} from "../src/ElyNames.sol";
import {ElyController} from "../src/ElyController.sol";
import {ElyControllerV3, ILegacyController} from "../src/ElyControllerV3.sol";
import {MockNFT, MockToken} from "./ElyNames.t.sol";
import {TreeData} from "./TreeData.sol";

contract ElyControllerV3Test is Test {
    ElyNames names;
    ElyController legacy;
    ElyControllerV3 v3;
    MockNFT kaola;
    MockToken partnerToken;

    address admin = address(0xA11CE);
    address treasury = address(0x7EA5);
    address partnerMgr = address(0xFEED);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    address carol = address(0xC4);
    address dave = address(0xD4); // not on any list
    bytes32 secret = keccak256("s");

    uint256 constant P_LONG = 0.1 ether;

    function setUp() public {
        vm.warp(1_800_000_000);
        kaola = new MockNFT();
        partnerToken = new MockToken();
        names = new ElyNames(admin, treasury, 300);
        legacy = new ElyController(names, kaola, treasury, admin, 0.3 ether, 0.2 ether, P_LONG, 5);
        v3 = new ElyControllerV3(names, ILegacyController(address(legacy)), treasury, admin, 0.3 ether, 0.2 ether, P_LONG);
        vm.startPrank(admin);
        names.setController(address(legacy), true);
        names.setController(address(v3), true);
        vm.stopPrank();
        for (uint160 i = 0xA1; i <= 0xD4; i++) vm.deal(address(i), 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ── helpers ──
    function _make(bytes32 root, uint16 bps, uint64 start, uint64 end, uint32 cap, uint8 minLen, bool legacyCheck)
        internal
        returns (uint256 id)
    {
        vm.prank(admin);
        id = v3.createProgram(
            ElyControllerV3.ProgramInput({
                name: "Test program",
                manager: partnerMgr,
                root: root,
                discountBps: bps,
                start: start,
                end: end,
                snapshotAt: start,
                cap: cap,
                minLength: minLen,
                checkLegacyKaola: legacyCheck,
                listURI: "https://example.com/list.json"
            })
        );
    }

    function _dex() internal returns (uint256) {
        return _make(TreeData.DEX_ROOT, 2000, uint64(block.timestamp), 0, 0, 0, false);
    }

    function _kaolaProgram() internal returns (uint256) {
        return _make(TreeData.KAOLA_ROOT, 10_000, uint64(block.timestamp), 0, 0, 5, true);
    }

    function _commit(address who, string memory label) internal {
        vm.prank(who);
        v3.commit(v3.makeCommitment(label, who, secret));
        skip(20);
    }

    function _claim(address who, string memory label, uint256 id, uint256 entry, bytes32[] memory proof, uint256 duration)
        internal
    {
        _commit(who, label);
        (uint256 price,) = v3.programPrice(label, duration, id, who);
        vm.prank(who);
        v3.registerWithProgram{value: price}(label, who, duration, secret, id, entry, proof);
    }

    // ── DEX volume list (20% off first year) ──

    function test_dex_eligibleGets20PercentOff() public {
        uint256 id = _dex();
        (uint256 price, uint16 bps) = v3.programPrice("longname", 365 days, id, alice);
        assertEq(bps, 2000);
        assertEq(price, 0.08 ether);
        _claim(alice, "longname", id, 0, TreeData.dexAlice(), 365 days);
        assertEq(names.ownerOf(names.idOf("longname")), alice);
        assertEq(treasury.balance + address(v3).balance, 0.08 ether);
    }

    function test_dex_discountIsFirstYearOnly() public {
        uint256 id = _dex();
        (uint256 price,) = v3.programPrice("longname", 3 * 365 days, id, alice);
        assertEq(price, 3 * P_LONG - 0.02 ether);
    }

    function test_dex_notOnList() public {
        uint256 id = _dex();
        _commit(dave, "longname");
        vm.prank(dave);
        vm.expectRevert(ElyControllerV3.NotEligible.selector);
        v3.registerWithProgram{value: 1 ether}("longname", dave, 365 days, secret, id, 0, TreeData.dexAlice());
        vm.prank(dave);
        vm.expectRevert(ElyControllerV3.NotEligible.selector);
        v3.registerWithProgram{value: 1 ether}("longname", dave, 365 days, secret, id, 0, new bytes32[](0));
    }

    function test_dex_proofIsBoundToTheSender() public {
        uint256 id = _dex();
        _commit(bob, "longname");
        vm.prank(bob); // bob tries alice's proof
        vm.expectRevert(ElyControllerV3.NotEligible.selector);
        v3.registerWithProgram{value: 1 ether}("longname", bob, 365 days, secret, id, 0, TreeData.dexAlice());
    }

    function test_dex_eachEntryUsedOnce() public {
        uint256 id = _dex();
        _claim(alice, "longname", id, 0, TreeData.dexAlice(), 365 days);
        _commit(alice, "secondname");
        vm.prank(alice);
        vm.expectRevert(ElyControllerV3.EntryAlreadyUsed.selector);
        v3.registerWithProgram{value: 1 ether}("secondname", alice, 365 days, secret, id, 0, TreeData.dexAlice());
    }

    // ── Kaola snapshot (free first year, 5+ characters) ──

    function test_kaola_snapshotHolderClaimsFree() public {
        uint256 id = _kaolaProgram();
        _claim(alice, "alicehq", id, 1, TreeData.kaolaAlice1(), 365 days);
        assertEq(names.ownerOf(names.idOf("alicehq")), alice);
        assertEq(names.nameExpires("alicehq"), block.timestamp + 365 days);
        assertEq(address(v3).balance, 0); // paid nothing
    }

    function test_kaola_buyerAfterSnapshotCannotClaim() public {
        uint256 id = _kaolaProgram();
        // dave bought a Kaola after the snapshot: he is not on the list, so he cannot claim token 1
        _commit(dave, "davehq1");
        vm.prank(dave);
        vm.expectRevert(ElyControllerV3.NotEligible.selector);
        v3.registerWithProgram("davehq1", dave, 365 days, secret, id, 1, TreeData.kaolaAlice1());
        vm.prank(dave);
        vm.expectRevert(ElyControllerV3.NotEligible.selector);
        v3.registerWithProgram("davehq1", dave, 365 days, secret, id, 1, new bytes32[](0));
    }

    function test_kaola_idAlreadyClaimedOnOldControllerIsRejected() public {
        kaola.mint(bob, 2);
        _commitLegacy(bob, "bobhq1");
        vm.prank(bob);
        legacy.claimFree("bobhq1", 2, secret); // claimed on the OLD controller
        uint256 id = _kaolaProgram();
        _commit(bob, "bobhq2");
        vm.prank(bob);
        vm.expectRevert(ElyControllerV3.AlreadyClaimedOnLegacy.selector);
        v3.registerWithProgram("bobhq2", bob, 365 days, secret, id, 2, TreeData.kaolaBob2());
        // carol's token 3 never claimed: still fine
        _claim(carol, "carolhq", id, 3, TreeData.kaolaCarol3(), 365 days);
        assertEq(names.ownerOf(names.idOf("carolhq")), carol);
    }

    function _commitLegacy(address who, string memory label) internal {
        vm.prank(who);
        legacy.commit(legacy.makeCommitment(label, who, secret));
        skip(20);
    }

    function test_kaola_minLengthEnforced() public {
        uint256 id = _kaolaProgram();
        _commit(alice, "abcd");
        vm.prank(alice);
        vm.expectRevert(ElyControllerV3.NameTooShortForProgram.selector);
        v3.registerWithProgram("abcd", alice, 365 days, secret, id, 1, TreeData.kaolaAlice1());
    }

    // ── program rules ──

    function test_program_timeWindow() public {
        uint256 id = _make(TreeData.DEX_ROOT, 2000, uint64(block.timestamp + 1 days), uint64(block.timestamp + 2 days), 0, 0, false);
        _commit(alice, "longname");
        vm.prank(alice);
        vm.expectRevert(ElyControllerV3.ProgramNotOpen.selector); // too early
        v3.registerWithProgram{value: 1 ether}("longname", alice, 365 days, secret, id, 0, TreeData.dexAlice());
        vm.warp(block.timestamp + 3 days);
        _commit(alice, "longname2");
        vm.prank(alice);
        vm.expectRevert(ElyControllerV3.ProgramNotOpen.selector); // too late
        v3.registerWithProgram{value: 1 ether}("longname2", alice, 365 days, secret, id, 0, TreeData.dexAlice());
    }

    function test_program_capReached() public {
        uint256 id = _make(TreeData.DEX_ROOT, 2000, uint64(block.timestamp), 0, 1, 0, false);
        _claim(alice, "longname", id, 0, TreeData.dexAlice(), 365 days);
        _commit(bob, "bobname1");
        vm.prank(bob);
        vm.expectRevert(ElyControllerV3.ProgramCapReached.selector);
        v3.registerWithProgram{value: 1 ether}("bobname1", bob, 365 days, secret, id, 0, TreeData.dexBob());
    }

    function test_program_canBePaused() public {
        uint256 id = _dex();
        vm.prank(admin);
        v3.setProgramActive(id, false);
        _commit(alice, "longname");
        vm.prank(alice);
        vm.expectRevert(ElyControllerV3.ProgramNotOpen.selector);
        v3.registerWithProgram{value: 1 ether}("longname", alice, 365 days, secret, id, 0, TreeData.dexAlice());
    }

    function test_program_rootLockedOnceStarted() public {
        uint256 id = _make(bytes32(0), 2000, uint64(block.timestamp + 1 days), 0, 0, 0, false);
        vm.prank(partnerMgr); // the partner publishes its list before the start
        v3.setProgramRoot(id, TreeData.DEX_ROOT, "https://partner.example/list.json");
        assertEq(v3.getProgram(id).root, TreeData.DEX_ROOT);

        vm.prank(dave);
        vm.expectRevert(ElyControllerV3.NotProgramManager.selector);
        v3.setProgramRoot(id, bytes32(uint256(1)), "x");

        vm.warp(block.timestamp + 1 days); // program starts: list is frozen for everyone, owner included
        vm.prank(partnerMgr);
        vm.expectRevert(ElyControllerV3.RootLocked.selector);
        v3.setProgramRoot(id, bytes32(uint256(1)), "x");
        vm.prank(admin);
        vm.expectRevert(ElyControllerV3.RootLocked.selector);
        v3.setProgramRoot(id, bytes32(uint256(1)), "x");
    }

    function test_program_onlyOwnerCreates() public {
        vm.prank(alice);
        vm.expectRevert();
        v3.createProgram(
            ElyControllerV3.ProgramInput(
                "x", alice, bytes32(0), 2000, uint64(block.timestamp), 0, 0, 0, 0, false, ""
            )
        );
    }

    function test_discount_bestOfProgramAndHolding_noStacking() public {
        uint256 id = _dex(); // 20%
        vm.prank(admin);
        v3.setPartner(address(partnerToken), 5000, 1); // 50% for token holders
        partnerToken.mint(alice, 1);
        (uint256 p1, uint16 bps1) = v3.programPrice("longname", 365 days, id, alice);
        assertEq(bps1, 5000);
        assertEq(p1, P_LONG / 2);
        (, uint16 bps2) = v3.programPrice("longname", 365 days, id, bob); // bob holds none: program's 20%
        assertEq(bps2, 2000);
    }

    function test_reservedNamesStillBlockedInPrograms() public {
        uint256 id = _dex();
        string[] memory l = new string[](1);
        l[0] = "elysium";
        vm.prank(admin);
        v3.setReserved(l, true);
        _commit(alice, "elysium");
        vm.prank(alice);
        vm.expectRevert(ElyControllerV3.NameReserved.selector);
        v3.registerWithProgram{value: 1 ether}("elysium", alice, 365 days, secret, id, 0, TreeData.dexAlice());
    }

    function test_checkClaim_codes() public {
        uint256 id = _dex();
        assertEq(v3.checkClaim(id, alice, 0, TreeData.dexAlice()), 0);
        assertEq(v3.checkClaim(id, dave, 0, TreeData.dexAlice()), 3);
        assertEq(v3.checkClaim(99, alice, 0, TreeData.dexAlice()), 1);
        _claim(alice, "longname", id, 0, TreeData.dexAlice(), 365 days);
        assertEq(v3.checkClaim(id, alice, 0, TreeData.dexAlice()), 4);
    }

    function test_program_underpaidAndRefund() public {
        uint256 id = _dex();
        _commit(alice, "longname");
        vm.prank(alice);
        vm.expectRevert(ElyControllerV3.InsufficientPayment.selector);
        v3.registerWithProgram{value: 0.079 ether}("longname", alice, 365 days, secret, id, 0, TreeData.dexAlice());
        uint256 before = alice.balance;
        vm.prank(alice);
        v3.registerWithProgram{value: 5 ether}("longname", alice, 365 days, secret, id, 0, TreeData.dexAlice());
        assertEq(before - alice.balance, 0.08 ether);
    }

    // ── "no names are wiped": the shared names contract keeps everything ──

    function test_existingNamesSurviveTheSwitch() public {
        // a name registered through the OLD controller before the switch
        vm.prank(alice);
        legacy.commit(legacy.makeCommitment("legacyname", alice, secret));
        skip(20);
        vm.prank(alice);
        legacy.register{value: P_LONG}("legacyname", alice, 365 days, secret);
        uint256 id = names.idOf("legacyname");
        vm.prank(alice);
        names.setText(id, "k", "v");

        // admin switches the old controller off
        vm.prank(admin);
        names.setController(address(legacy), false);

        // the name, its owner and its records are all intact
        assertEq(names.ownerOf(id), alice);
        assertEq(names.resolve("legacyname"), alice);
        assertEq(names.text("legacyname", "k"), "v");

        // the new controller can renew it
        uint256 exp = names.nameExpires("legacyname");
        vm.prank(bob); // anyone can renew
        v3.renew{value: P_LONG}("legacyname", 365 days);
        assertEq(names.nameExpires("legacyname"), exp + 365 days);

        // the old controller can no longer register anything
        vm.prank(carol);
        legacy.commit(legacy.makeCommitment("anothername", carol, secret));
        skip(20);
        vm.prank(carol);
        vm.expectRevert(ElyNames.NotController.selector);
        legacy.register{value: P_LONG}("anothername", carol, 365 days, secret);
    }

    function test_withdrawToTreasury() public {
        _buyPlain(alice, "longname");
        vm.prank(admin);
        v3.withdraw();
        assertEq(treasury.balance, P_LONG);
    }

    function _buyPlain(address who, string memory label) internal {
        _commit(who, label);
        vm.prank(who);
        v3.register{value: P_LONG}(label, who, 365 days, secret);
    }
}
