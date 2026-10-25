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

/// @title ElyControllerV4
/// @notice The shop. Replaces V3 WITHOUT touching ElyNames (every name, record and expiry stays).
///         Adds: referrals, a fair expiry premium, and registering a name straight to another wallet.
///         One rule for all discounts: the BEST single discount applies, they never add together.
contract ElyControllerV4 is Ownable2Step, ReentrancyGuard {
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_DURATION = 10 * 365 days;
    uint256 public constant MIN_RENEWAL = 30 days;
    uint256 public constant MIN_COMMITMENT_AGE = 15 seconds;
    uint256 public constant MAX_COMMITMENT_AGE = 24 hours;
    uint256 public constant MAX_PARTNERS = 50;
    uint16 public constant MAX_REFERRAL_BPS = 2500; // neither referral setting can exceed 25%

    ElyNames public immutable names;
    ILegacyController public immutable legacy; // first controller, used only for Kaola ids that already claimed (may be 0)

    uint256 public priceShort; // 2-3 characters, HYPE per year
    uint256 public priceMid; //   4-5 characters
    uint256 public priceLong; //  6+ characters
    address public treasury;

    // ── Expiry premium: after the grace period a name starts at `premiumStart` and falls linearly to 0 ──
    uint256 public premiumStart = 2 ether;
    uint256 public premiumPeriod = 14 days;

    // ── Referrals ──
    uint16 public referralRewardBps = 500; //   the referrer earns 5% of what the new user pays (before the premium)
    uint16 public referralDiscountBps = 500; // the new user gets 5% off the first year
    uint256 public totalReferralOwed;
    mapping(address => uint256) public referralOwed;

    // ── Programs (snapshot lists), unchanged in spirit from V3 ──
    struct Program {
        bytes32 root;
        address manager;
        uint16 discountBps;
        uint64 start;
        uint64 end;
        uint64 snapshotAt;
        uint32 cap;
        uint32 used;
        uint8 minLength;
        bool active;
        bool checkLegacyKaola;
        string name;
        string listURI;
    }

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

    struct RegisterArgs {
        string label;
        address owner; //     who receives the name (can be a different, safer wallet than the payer)
        uint256 duration;
        bytes32 secret;
        address referrer; //  address(0) for none
        uint256 programId; // 0 for none
        uint256 entryId; //   token id for NFT lists, 0 for wallet lists
    }

    struct Quote {
        uint256 base; //          price before any discount
        uint16 discountBps; //    the single best discount that applies
        uint256 afterDiscount; // base minus the discount (first year only)
        uint256 premium; //       expiry premium, never discounted
        uint256 total; //         what the buyer pays
        uint256 reward; //        what the referrer earns (0 if no valid referral)
    }

    uint256 public programCount;
    mapping(uint256 => Program) private _programs;
    mapping(uint256 => mapping(bytes32 => bool)) public entryUsed;

    // ── Balance-based partner discounts (unchanged) ──
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
    event Referral(address indexed referrer, address indexed buyer, string label, uint256 reward);
    event ReferralWithdrawn(address indexed referrer, uint256 amount);
    event ReferralSettingsChanged(uint16 rewardBps, uint16 discountBps);
    event PremiumChanged(uint256 start, uint256 period);
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
    error NotEligible();
    error EntryAlreadyUsed();
    error AlreadyClaimedOnLegacy();
    error NothingToClaim();

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

    /// @notice Extra price on a name that expired and is open to everyone again.
    ///         Starts when the names contract's grace period ends and falls linearly to zero.
    function premiumFor(string memory label) public view returns (uint256) {
        uint256 exp = names.nameExpires(label);
        if (exp == 0) return 0; // never registered
        uint256 start = exp + names.GRACE_PERIOD();
        if (block.timestamp >= start + premiumPeriod) return 0;
        if (block.timestamp <= start) return premiumStart;
        return (premiumStart * (start + premiumPeriod - block.timestamp)) / premiumPeriod;
    }

    function isEligibleReferrer(address r) public view returns (bool) {
        return r != address(0) && bytes(names.primaryNameOf(r)).length != 0; // must hold an active primary name
    }

    function _quote(string memory label, uint256 duration, address buyer, address owner_, address referrer, uint16 programBps)
        internal
        view
        returns (Quote memory q)
    {
        uint256 yearly = pricePerYear(label);
        q.base = (yearly * duration) / YEAR;

        // one discount only: the best of the three
        uint16 best = discountBpsOf(buyer);
        if (programBps > best) best = programBps;
        bool referred = referrer != buyer && referrer != owner_ && isEligibleReferrer(referrer);
        if (referred && referralDiscountBps > best) best = referralDiscountBps;

        q.discountBps = best;
        q.afterDiscount = q.base - (yearly * best) / 10_000; // discount applies to the first year only
        q.premium = premiumFor(label); // the premium is never discounted
        q.total = q.afterDiscount + q.premium;
        if (referred) q.reward = (q.afterDiscount * referralRewardBps) / 10_000; // reward excludes the premium
    }

    /// @notice Everything the website needs to show a price. `programCode` is 0 when the program entry is valid.
    function quote(RegisterArgs calldata a, address buyer, bytes32[] calldata proof)
        external
        view
        returns (Quote memory q, uint8 programCode)
    {
        uint16 programBps;
        if (a.programId != 0) {
            programCode = _check(a.programId, buyer, a.entryId, proof);
            if (programCode == 0) programBps = _programs[a.programId].discountBps;
        }
        q = _quote(a.label, a.duration, buyer, a.owner, a.referrer, programBps);
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

    /// @notice One entry point for every registration: plain, partner program, referral, or any mix.
    function register(RegisterArgs calldata a, bytes32[] calldata proof) external payable nonReentrant {
        if (a.duration < YEAR || a.duration > MAX_DURATION) revert BadDuration();
        if (isReserved(a.label)) revert NameReserved();
        _consume(makeCommitment(a.label, a.owner, a.secret));

        uint16 programBps;
        if (a.programId != 0) {
            Program storage p = _programs[a.programId];
            if (bytes(a.label).length < p.minLength) revert NameTooShortForProgram();
            _useEntry(a.programId, p, msg.sender, a.entryId, proof);
            programBps = p.discountBps;
            emit ProgramClaimed(a.programId, msg.sender, a.entryId, a.label);
        }

        Quote memory q = _quote(a.label, a.duration, msg.sender, a.owner, a.referrer, programBps);
        if (msg.value < q.total) revert InsufficientPayment();

        names.register(a.label, a.owner, a.duration);
        emit NameRegistered(a.label, a.owner, q.total, q.discountBps, a.duration);

        if (q.reward != 0) {
            referralOwed[a.referrer] += q.reward;
            totalReferralOwed += q.reward;
            emit Referral(a.referrer, msg.sender, a.label, q.reward);
        }
        if (msg.value > q.total) _send(msg.sender, msg.value - q.total);
    }

    function renew(string calldata label, uint256 duration) external payable nonReentrant {
        if (duration < MIN_RENEWAL || duration > MAX_DURATION) revert BadDuration();
        uint256 price = renewPrice(label, duration);
        if (msg.value < price) revert InsufficientPayment();

        names.renew(label, duration);
        emit NameRenewed(label, msg.sender, price, duration);

        if (msg.value > price) _send(msg.sender, msg.value - price);
    }

    // ───────────────────────── referral payouts ─────────────────────────

    /// @notice A referrer withdraws everything they have earned.
    function claimReferral() external nonReentrant {
        uint256 amount = referralOwed[msg.sender];
        if (amount == 0) revert NothingToClaim();
        referralOwed[msg.sender] = 0;
        totalReferralOwed -= amount;
        _send(msg.sender, amount);
        emit ReferralWithdrawn(msg.sender, amount);
    }

    // ───────────────────────── programs ─────────────────────────

    function leafOf(address account, uint256 entryId) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, entryId))));
    }

    function _check(uint256 id, address account, uint256 entryId, bytes32[] calldata proof) internal view returns (uint8) {
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

    function _useEntry(uint256 id, Program storage p, address account, uint256 entryId, bytes32[] calldata proof)
        internal
    {
        if (id == 0 || id > programCount) revert ProgramNotFound();
        uint8 code = _check(id, account, entryId, proof);
        if (code == 1) revert ProgramNotOpen();
        if (code == 2) revert ProgramCapReached();
        if (code == 3) revert NotEligible();
        if (code == 4) revert EntryAlreadyUsed();
        if (code == 5) revert AlreadyClaimedOnLegacy();
        entryUsed[id][leafOf(account, entryId)] = true;
        p.used += 1;
    }

    /// @notice For the website: 0 = can claim, 1 = program not open, 2 = cap reached, 3 = not on the list,
    ///         4 = already used, 5 = already claimed on the first controller.
    function checkClaim(uint256 id, address account, uint256 entryId, bytes32[] calldata proof)
        external
        view
        returns (uint8)
    {
        return _check(id, account, entryId, proof);
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

    function setPremium(uint256 start, uint256 period) external onlyOwner {
        if (period == 0 || period > 90 days || start > 100 ether) revert BadParam();
        premiumStart = start;
        premiumPeriod = period;
        emit PremiumChanged(start, period);
    }

    function setReferral(uint16 rewardBps, uint16 discountBps) external onlyOwner {
        if (rewardBps > MAX_REFERRAL_BPS || discountBps > MAX_REFERRAL_BPS) revert BadParam();
        referralRewardBps = rewardBps;
        referralDiscountBps = discountBps;
        emit ReferralSettingsChanged(rewardBps, discountBps);
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

    /// @notice Sends the shop's earnings to the treasury. Money owed to referrers is never touched.
    function withdraw() external onlyOwner {
        uint256 amount = address(this).balance - totalReferralOwed;
        _send(treasury, amount);
        emit Withdrawn(treasury, amount);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
