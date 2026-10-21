// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ElyNames} from "./ElyNames.sol";

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

interface ILegacyController {
    function kaolaClaimed(uint256 id) external view returns (bool);
}

/// @title ElyControllerV3
/// @notice Replaces the original controller WITHOUT touching ElyNames (all names, records and expiries stay).
///         Adds "programs": a partner's snapshot list is published on-chain as a Merkle root, and eligible
///         wallets prove they are on it when registering. Each list entry can be used once.
contract ElyControllerV3 is Ownable2Step, ReentrancyGuard {
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_DURATION = 10 * 365 days;
    uint256 public constant MIN_RENEWAL = 30 days;
    uint256 public constant MIN_COMMITMENT_AGE = 15 seconds;
    uint256 public constant MAX_COMMITMENT_AGE = 24 hours;
    uint256 public constant MAX_PARTNERS = 50;

    ElyNames public immutable names;
    /// @notice The old controller, used only to honour Kaola IDs that already claimed. May be address(0).
    ILegacyController public immutable legacy;

    uint256 public priceShort; // 2-3 characters, HYPE per year
    uint256 public priceMid; //   4-5 characters
    uint256 public priceLong; //  6+ characters
    address public treasury;

    // ── Programs (snapshot lists) ──
    struct Program {
        bytes32 root; //        Merkle root of the published list
        address manager; //     partner or owner; may update the root until the program starts
        uint16 discountBps; //  discount on the FIRST year (2000 = 20%, 10000 = free first year)
        uint64 start; //        claims open at this time; the root is locked from this moment
        uint64 end; //          claims close (0 = never)
        uint64 snapshotAt; //   when the snapshot was taken (published for transparency)
        uint32 cap; //          maximum total claims (0 = unlimited)
        uint32 used; //         claims so far
        uint8 minLength; //     shortest name allowed with this program
        bool active; //         owner can pause
        bool checkLegacyKaola; // also reject token ids already claimed on the old controller
        string name;
        string listURI; //      where anyone can download the full list
    }

    uint256 public programCount;
    mapping(uint256 => Program) private _programs;
    mapping(uint256 => mapping(bytes32 => bool)) public entryUsed; // programId => leaf => used

    struct ProgramInput {
        string name;
        address manager;
        bytes32 root;
        uint16 discountBps;
        uint64 start;
        uint64 end;
        uint64 snapshotAt;
        uint32 cap;
        uint8 minLength;
        bool checkLegacyKaola;
        string listURI;
    }

    // ── Balance-based partner discounts (unchanged from the original controller) ──
    struct Partner {
        uint16 discountBps;
        uint256 minBalance;
        bool listed;
    }
    address[] public partnerList;
    mapping(address => Partner) public partners;

    mapping(bytes32 => uint256) public commitments;
    mapping(bytes32 => bool) private _reserved;

    event ProgramCreated(uint256 indexed id, string name, address manager);
    event ProgramRootSet(uint256 indexed id, bytes32 root, string listURI);
    event ProgramActive(uint256 indexed id, bool active);
    event ProgramClaimed(uint256 indexed id, address indexed account, uint256 entryId, string label);
    event NameRegistered(string label, address indexed owner, uint256 price, uint16 discountBps, uint256 duration);
    event NameRenewed(string label, address indexed payer, uint256 price, uint256 duration);
    event PricesChanged(uint256 priceShort, uint256 priceMid, uint256 priceLong);
    event PartnerSet(address indexed token, uint16 discountBps, uint256 minBalance);
    event ReservedSet(string label, bool reserved);
    event TreasuryChanged(address treasury);
    event Withdrawn(address indexed to, uint256 amount);

    error CommitmentMissing();
    error CommitmentTooNew();
    error CommitmentExpired();
    error CommitmentExists();
    error BadDuration();
    error InsufficientPayment();
    error NameReserved();
    error BadParam();
    error TransferFailed();
    error NotProgramManager();
    error ProgramNotFound();
    error ProgramNotOpen();
    error ProgramCapReached();
    error NameTooShortForProgram();
    error RootLocked();
    error NotEligible(); //          the sender is not on the list (or the proof is wrong)
    error EntryAlreadyUsed();
    error AlreadyClaimedOnLegacy();

    constructor(
        ElyNames names_,
        ILegacyController legacy_,
        address treasury_,
        address initialOwner,
        uint256 priceShort_,
        uint256 priceMid_,
        uint256 priceLong_
    ) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert BadParam();
        names = names_;
        legacy = legacy_;
        treasury = treasury_;
        priceShort = priceShort_;
        priceMid = priceMid_;
        priceLong = priceLong_;
    }

    // ───────────────────────── pricing ─────────────────────────

    function pricePerYear(string memory label) public view returns (uint256) {
        uint256 len = bytes(label).length;
        if (len <= 3) return priceShort;
        if (len <= 5) return priceMid;
        return priceLong;
    }

    function discountBpsOf(address buyer) public view returns (uint16 best) {
        uint256 n = partnerList.length;
        for (uint256 i; i < n; ++i) {
            address token = partnerList[i];
            Partner memory p = partners[token];
            if (p.discountBps <= best) continue;
            try IBalanceOf(token).balanceOf(buyer) returns (uint256 bal) {
                if (bal >= p.minBalance && bal > 0) best = p.discountBps;
            } catch {}
        }
    }

    function _price(string memory label, uint256 duration, uint16 bps) internal view returns (uint256) {
        uint256 yearly = pricePerYear(label);
        return (yearly * duration) / YEAR - (yearly * bps) / 10_000;
    }

    /// @notice Normal registration price (balance-based partner discount only).
    function registerPrice(string memory label, uint256 duration, address buyer)
        public
        view
        returns (uint256 price, uint16 discountBps)
    {
        discountBps = discountBpsOf(buyer);
        price = _price(label, duration, discountBps);
    }

    /// @notice Price when registering through a program. The better of the two discounts applies (they do not stack).
    function programPrice(string memory label, uint256 duration, uint256 programId, address buyer)
        public
        view
        returns (uint256 price, uint16 discountBps)
    {
        discountBps = _programs[programId].discountBps;
        uint16 partnerBps = discountBpsOf(buyer);
        if (partnerBps > discountBps) discountBps = partnerBps;
        price = _price(label, duration, discountBps);
    }

    function renewPrice(string memory label, uint256 duration) public view returns (uint256) {
        return (pricePerYear(label) * duration) / YEAR;
    }

    // ───────────────────── commit-reveal ─────────────────────

    function makeCommitment(string memory label, address owner, bytes32 secret) public pure returns (bytes32) {
        return keccak256(abi.encode(label, owner, secret));
    }

    function commit(bytes32 commitment) external {
        if (commitments[commitment] + MAX_COMMITMENT_AGE >= block.timestamp) revert CommitmentExists();
        commitments[commitment] = block.timestamp;
    }

    function _consume(bytes32 commitment) internal {
        uint256 t = commitments[commitment];
        if (t == 0) revert CommitmentMissing();
        if (t + MIN_COMMITMENT_AGE > block.timestamp) revert CommitmentTooNew();
        if (t + MAX_COMMITMENT_AGE <= block.timestamp) revert CommitmentExpired();
        delete commitments[commitment];
    }

    // ───────────────────────── registration ─────────────────────────

    function register(string calldata label, address owner, uint256 duration, bytes32 secret)
        external
        payable
        nonReentrant
    {
        if (duration < YEAR || duration > MAX_DURATION) revert BadDuration();
        if (isReserved(label)) revert NameReserved();
        _consume(makeCommitment(label, owner, secret));

        (uint256 price, uint16 bps) = registerPrice(label, duration, msg.sender);
        _finish(label, owner, duration, price, bps);
    }

    /// @notice Register using a program (a partner or snapshot list). `entryId` is the token id for NFT lists, 0 for wallet lists.
    function registerWithProgram(
        string calldata label,
        address owner,
        uint256 duration,
        bytes32 secret,
        uint256 programId,
        uint256 entryId,
        bytes32[] calldata proof
    ) external payable nonReentrant {
        if (duration < YEAR || duration > MAX_DURATION) revert BadDuration();
        if (isReserved(label)) revert NameReserved();
        Program storage p = _programs[programId];
        if (bytes(label).length < p.minLength) revert NameTooShortForProgram();
        _consume(makeCommitment(label, owner, secret));

        _useEntry(programId, p, msg.sender, entryId, proof);

        (uint256 price, uint16 bps) = programPrice(label, duration, programId, msg.sender);
        emit ProgramClaimed(programId, msg.sender, entryId, label);
        _finish(label, owner, duration, price, bps);
    }

    function _finish(string calldata label, address owner, uint256 duration, uint256 price, uint16 bps) internal {
        if (msg.value < price) revert InsufficientPayment();
        names.register(label, owner, duration);
        emit NameRegistered(label, owner, price, bps, duration);
        if (msg.value > price) _send(msg.sender, msg.value - price);
    }

    function renew(string calldata label, uint256 duration) external payable nonReentrant {
        if (duration < MIN_RENEWAL || duration > MAX_DURATION) revert BadDuration();
        uint256 price = renewPrice(label, duration);
        if (msg.value < price) revert InsufficientPayment();

        names.renew(label, duration);
        emit NameRenewed(label, msg.sender, price, duration);

        if (msg.value > price) _send(msg.sender, msg.value - price);
    }

    // ───────────────────────── programs ─────────────────────────

    function leafOf(address account, uint256 entryId) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, entryId))));
    }

    function _useEntry(uint256 id, Program storage p, address account, uint256 entryId, bytes32[] calldata proof)
        internal
    {
        if (id == 0 || id > programCount) revert ProgramNotFound();
        if (!p.active || block.timestamp < p.start || (p.end != 0 && block.timestamp > p.end)) revert ProgramNotOpen();
        if (p.cap != 0 && p.used >= p.cap) revert ProgramCapReached();
        bytes32 leaf = leafOf(account, entryId);
        if (!MerkleProof.verifyCalldata(proof, p.root, leaf)) revert NotEligible();
        if (entryUsed[id][leaf]) revert EntryAlreadyUsed();
        if (p.checkLegacyKaola && address(legacy) != address(0) && legacy.kaolaClaimed(entryId)) {
            revert AlreadyClaimedOnLegacy();
        }
        entryUsed[id][leaf] = true;
        p.used += 1;
    }

    /// @notice For the website: 0 = can claim, 1 = program not open, 2 = cap reached, 3 = not on the list,
    ///         4 = already used, 5 = already claimed on the old controller.
    function checkClaim(uint256 id, address account, uint256 entryId, bytes32[] calldata proof)
        external
        view
        returns (uint8)
    {
        if (id == 0 || id > programCount) return 1;
        Program storage p = _programs[id];
        if (!p.active || block.timestamp < p.start || (p.end != 0 && block.timestamp > p.end)) return 1;
        if (p.cap != 0 && p.used >= p.cap) return 2;
        bytes32 leaf = leafOf(account, entryId);
        if (!MerkleProof.verifyCalldata(proof, p.root, leaf)) return 3;
        if (entryUsed[id][leaf]) return 4;
        if (p.checkLegacyKaola && address(legacy) != address(0) && legacy.kaolaClaimed(entryId)) return 5;
        return 0;
    }

    function getProgram(uint256 id) external view returns (Program memory) {
        return _programs[id];
    }

    function createProgram(ProgramInput calldata in_) external onlyOwner returns (uint256 id) {
        if (in_.manager == address(0) || in_.discountBps > 10_000 || (in_.end != 0 && in_.end <= in_.start)) {
            revert BadParam();
        }
        id = ++programCount;
        Program storage p = _programs[id];
        p.root = in_.root;
        p.manager = in_.manager;
        p.discountBps = in_.discountBps;
        p.start = in_.start;
        p.end = in_.end;
        p.snapshotAt = in_.snapshotAt;
        p.cap = in_.cap;
        p.minLength = in_.minLength;
        p.active = true;
        p.checkLegacyKaola = in_.checkLegacyKaola;
        p.name = in_.name;
        p.listURI = in_.listURI;
        emit ProgramCreated(id, in_.name, in_.manager);
        emit ProgramRootSet(id, in_.root, in_.listURI);
    }

    /// @notice The owner or the program's manager can publish/replace the list, but only BEFORE the program starts.
    function setProgramRoot(uint256 id, bytes32 root, string calldata listURI) external {
        if (id == 0 || id > programCount) revert ProgramNotFound();
        Program storage p = _programs[id];
        if (msg.sender != owner() && msg.sender != p.manager) revert NotProgramManager();
        if (block.timestamp >= p.start) revert RootLocked();
        p.root = root;
        p.listURI = listURI;
        emit ProgramRootSet(id, root, listURI);
    }

    function setProgramActive(uint256 id, bool active) external onlyOwner {
        if (id == 0 || id > programCount) revert ProgramNotFound();
        _programs[id].active = active;
        emit ProgramActive(id, active);
    }

    function setProgramManager(uint256 id, address manager) external onlyOwner {
        if (id == 0 || id > programCount || manager == address(0)) revert BadParam();
        _programs[id].manager = manager;
    }

    // ───────────────────────── reserved names ─────────────────────────

    function isReserved(string memory label) public view returns (bool) {
        return _reserved[keccak256(bytes(label))];
    }

    function setReserved(string[] calldata labels, bool value) external onlyOwner {
        for (uint256 i; i < labels.length; ++i) {
            _reserved[keccak256(bytes(labels[i]))] = value;
            emit ReservedSet(labels[i], value);
        }
    }

    function registerReserved(string calldata label, address to, uint256 duration) external onlyOwner nonReentrant {
        if (!isReserved(label)) revert BadParam();
        if (duration == 0 || duration > MAX_DURATION) revert BadDuration();
        names.register(label, to, duration);
        emit NameRegistered(label, to, 0, 0, duration);
    }

    // ───────────────────────── owner settings ─────────────────────────

    function setPrices(uint256 priceShort_, uint256 priceMid_, uint256 priceLong_) external onlyOwner {
        priceShort = priceShort_;
        priceMid = priceMid_;
        priceLong = priceLong_;
        emit PricesChanged(priceShort_, priceMid_, priceLong_);
    }

    function setPartner(address token, uint16 discountBps, uint256 minBalance) external onlyOwner {
        if (token == address(0) || discountBps > 10_000) revert BadParam();
        Partner storage p = partners[token];
        if (!p.listed) {
            if (partnerList.length >= MAX_PARTNERS) revert BadParam();
            p.listed = true;
            partnerList.push(token);
        }
        p.discountBps = discountBps;
        p.minBalance = minBalance == 0 ? 1 : minBalance;
        emit PartnerSet(token, discountBps, p.minBalance);
    }

    function partnerCount() external view returns (uint256) {
        return partnerList.length;
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert BadParam();
        treasury = treasury_;
        emit TreasuryChanged(treasury_);
    }

    function withdraw() external onlyOwner {
        uint256 amount = address(this).balance;
        _send(treasury, amount);
        emit Withdrawn(treasury, amount);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
