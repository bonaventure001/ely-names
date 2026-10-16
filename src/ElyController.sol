// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ElyNames} from "./ElyNames.sol";

interface IBalanceOf {
    function balanceOf(address account) external view returns (uint256);
}

/// @title ElyController
/// @notice Sells `.ely` names in HYPE. Handles pricing, commit-reveal, the free Kaola claim,
///         and first-year partner discounts. Everything tunable is an owner setter (no redeploy).
contract ElyController is Ownable2Step, ReentrancyGuard {
    uint256 public constant YEAR = 365 days;
    uint256 public constant MAX_DURATION = 10 * 365 days;
    uint256 public constant MIN_RENEWAL = 30 days;
    uint256 public constant MIN_COMMITMENT_AGE = 15 seconds;
    uint256 public constant MAX_COMMITMENT_AGE = 24 hours;
    uint256 public constant MAX_PARTNERS = 50;

    ElyNames public immutable names;
    IERC721 public immutable kaola;

    // Prices are HYPE (wei) per year.
    uint256 public priceShort; // 2-3 characters
    uint256 public priceMid; //   4-5 characters
    uint256 public priceLong; //  6+ characters
    address public treasury;

    // Free claim for Kaola holders: one name per Kaola token id, ever.
    bool public freeClaimOpen = true;
    uint256 public freeMinLength;
    mapping(uint256 => bool) public kaolaClaimed;

    // Partner discounts (first year only, registration only).
    struct Partner {
        uint16 discountBps; // 10000 = 100%; 0 = disabled
        uint256 minBalance; // balance of `token` needed to qualify (1 for NFTs)
        bool listed;
    }
    address[] public partnerList;
    mapping(address => Partner) public partners;

    mapping(bytes32 => uint256) public commitments;

    event NameRegistered(string label, address indexed owner, uint256 price, uint16 discountBps, uint256 duration);
    event FreeClaimed(string label, address indexed owner, uint256 indexed kaolaId);
    event NameRenewed(string label, address indexed payer, uint256 price, uint256 duration);
    event PricesChanged(uint256 priceShort, uint256 priceMid, uint256 priceLong);
    event PartnerSet(address indexed token, uint16 discountBps, uint256 minBalance);
    event TreasuryChanged(address treasury);
    event Withdrawn(address indexed to, uint256 amount);

    error CommitmentMissing();
    error CommitmentTooNew();
    error CommitmentExpired();
    error CommitmentExists();
    error BadDuration();
    error InsufficientPayment();
    error FreeClaimClosed();
    error NameTooShortForFreeClaim();
    error NotKaolaOwner();
    error KaolaAlreadyClaimed();
    error BadParam();
    error TransferFailed();

    constructor(
        ElyNames names_,
        IERC721 kaola_,
        address treasury_,
        address initialOwner,
        uint256 priceShort_,
        uint256 priceMid_,
        uint256 priceLong_,
        uint256 freeMinLength_
    ) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert BadParam();
        names = names_;
        kaola = kaola_;
        treasury = treasury_;
        priceShort = priceShort_;
        priceMid = priceMid_;
        priceLong = priceLong_;
        freeMinLength = freeMinLength_;
    }

    // ───────────────────────── pricing ─────────────────────────

    function pricePerYear(string memory label) public view returns (uint256) {
        uint256 len = bytes(label).length;
        if (len <= 3) return priceShort;
        if (len <= 5) return priceMid;
        return priceLong;
    }

    /// @notice Best partner discount (in bps) this buyer qualifies for.
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

    /// @notice Price to register `label` for `duration`. The partner discount only reduces the first year.
    function registerPrice(string memory label, uint256 duration, address buyer)
        public
        view
        returns (uint256 price, uint16 discountBps)
    {
        uint256 yearly = pricePerYear(label);
        discountBps = discountBpsOf(buyer);
        price = (yearly * duration) / YEAR - (yearly * discountBps) / 10_000;
    }

    function renewPrice(string memory label, uint256 duration) public view returns (uint256) {
        return (pricePerYear(label) * duration) / YEAR;
    }

    // ───────────────────── commit-reveal (anti-front-running) ─────────────────────

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
        _consume(makeCommitment(label, owner, secret));

        (uint256 price, uint16 bps) = registerPrice(label, duration, msg.sender);
        if (msg.value < price) revert InsufficientPayment();

        names.register(label, owner, duration);
        emit NameRegistered(label, owner, price, bps, duration);

        if (msg.value > price) _send(msg.sender, msg.value - price);
    }

    /// @notice Claim one free 1-year name with a Kaola NFT. Each Kaola id can claim exactly once, ever.
    function claimFree(string calldata label, uint256 kaolaId, bytes32 secret) external nonReentrant {
        if (!freeClaimOpen) revert FreeClaimClosed();
        if (bytes(label).length < freeMinLength) revert NameTooShortForFreeClaim();
        if (kaola.ownerOf(kaolaId) != msg.sender) revert NotKaolaOwner();
        if (kaolaClaimed[kaolaId]) revert KaolaAlreadyClaimed();

        kaolaClaimed[kaolaId] = true;
        _consume(makeCommitment(label, msg.sender, secret));
        names.register(label, msg.sender, YEAR);
        emit FreeClaimed(label, msg.sender, kaolaId);
    }

    /// @notice Anyone can renew any name. Renewals are full price (no partner discount).
    function renew(string calldata label, uint256 duration) external payable nonReentrant {
        if (duration < MIN_RENEWAL || duration > MAX_DURATION) revert BadDuration();
        uint256 price = renewPrice(label, duration);
        if (msg.value < price) revert InsufficientPayment();

        names.renew(label, duration);
        emit NameRenewed(label, msg.sender, price, duration);

        if (msg.value > price) _send(msg.sender, msg.value - price);
    }

    // ───────────────────────── owner settings ─────────────────────────

    function setPrices(uint256 priceShort_, uint256 priceMid_, uint256 priceLong_) external onlyOwner {
        priceShort = priceShort_;
        priceMid = priceMid_;
        priceLong = priceLong_;
        emit PricesChanged(priceShort_, priceMid_, priceLong_);
    }

    /// @notice Add or update a partner. `discountBps` 0 switches the partner off.
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

    function setFreeClaimOpen(bool open) external onlyOwner {
        freeClaimOpen = open;
    }

    function setFreeMinLength(uint256 minLength) external onlyOwner {
        freeMinLength = minLength;
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert BadParam();
        treasury = treasury_;
        emit TreasuryChanged(treasury_);
    }

    /// @notice Send all collected HYPE to the treasury wallet.
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
