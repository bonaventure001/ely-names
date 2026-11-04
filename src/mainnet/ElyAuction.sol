// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IAuctionNames {
    function register(string calldata label, address owner, uint256 duration) external returns (uint64);
    function available(string memory label) external view returns (bool);
}

/// @title ElyAuction
/// @notice English auctions for the scarce 1 and 2 character names, run one after another.
///         The highest bid when time runs out wins; the name is registered straight to the winner.
///         Bids are held by this contract. An outbid bidder takes their money back with withdraw()
///         (pull payments), so no bidder can block anyone else. There is NO time extension: a last-second bid can win.
///         This contract must be an authorized controller on the names contract, and the names it sells
///         must be on the shop's reserved list so nobody can buy them directly before their auction.
contract ElyAuction is Ownable2Step, ReentrancyGuard {
    uint16 public constant MAX_RAISE_BPS = 2500; // the minimum raise can never be set above 25%
    uint256 public constant MAX_LABEL_LENGTH = 2;
    uint256 public constant MAX_BATCH = 50;

    IAuctionNames public immutable names;
    address public treasury;
    uint256 public reserve = 1 ether; //          minimum first bid, in HYPE
    uint16 public minRaiseBps = 500; //           each bid must beat the last by at least 5%
    uint256 public termDuration = 365 days; //    how long the winner's registration lasts

    struct Auction {
        uint64 start;
        uint64 end;
        address highBidder;
        uint256 highBid;
        bool settled;
        bool exists;
    }

    mapping(bytes32 => Auction) private _auctions;
    string[] private _labels;
    mapping(address => uint256) public pendingReturns; // money owed back to outbid bidders
    uint256 public proceeds; //                          money from finished auctions, owed to the treasury

    event AuctionScheduled(string label, uint64 start, uint64 end);
    event AuctionCancelled(string label);
    event BidPlaced(string label, address indexed bidder, uint256 amount, uint64 end);
    event AuctionSettled(string label, address indexed winner, uint256 amount, bool registered);
    event Withdrawn(address indexed bidder, uint256 amount);
    event ProceedsSent(address indexed treasury, uint256 amount);
    event SettingsChanged(uint256 reserve, uint16 minRaiseBps, uint256 termDuration, address treasury);

    error BadParam();
    error NoSuchAuction();
    error NotOpen();
    error BidTooLow();
    error NotEnded();
    error AlreadySettled();
    error HasBids();
    error NothingToWithdraw();
    error TransferFailed();
    error LabelUnavailable();

    constructor(IAuctionNames names_, address treasury_, address initialOwner) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert BadParam();
        names = names_;
        treasury = treasury_;
    }

    // ───────────────────────── scheduling (owner) ─────────────────────────

    /// @notice Schedule auctions one after another: label i runs for `duration` starting at firstStart + i*(duration+gap).
    ///         `gap` is the pause between two auctions. Example: 36 names, 4 hours each, 40 minutes between = exactly 7 days.
    ///         A label whose earlier auction ended with no bids can be scheduled again.
    function schedule(string[] calldata labels, uint64 firstStart, uint64 duration, uint64 gap) external onlyOwner {
        if (labels.length == 0 || labels.length > MAX_BATCH) revert BadParam();
        if (firstStart < block.timestamp || duration < 1 hours || duration > 7 days || gap > 1 days) revert BadParam();
        for (uint256 i; i < labels.length; ++i) {
            uint256 len = bytes(labels[i]).length;
            if (len == 0 || len > MAX_LABEL_LENGTH) revert BadParam();
            bytes32 key = keccak256(bytes(labels[i]));
            Auction storage a = _auctions[key];
            bool reusable = a.exists && a.settled && a.highBidder == address(0);
            if (a.exists && !reusable) revert BadParam();
            if (!names.available(labels[i])) revert LabelUnavailable();
            uint64 start = firstStart + uint64(i) * (duration + gap);
            if (!a.exists) _labels.push(labels[i]);
            _auctions[key] = Auction({start: start, end: start + duration, highBidder: address(0), highBid: 0, settled: false, exists: true});
            emit AuctionScheduled(labels[i], start, start + duration);
        }
    }

    /// @notice Remove an auction that has no bids (scheduled by mistake, or to change its time).
    function cancel(string calldata label) external onlyOwner {
        bytes32 key = keccak256(bytes(label));
        Auction storage a = _auctions[key];
        if (!a.exists || a.settled) revert NoSuchAuction();
        if (a.highBidder != address(0)) revert HasBids();
        delete _auctions[key];
        emit AuctionCancelled(label);
    }

    // ───────────────────────── bidding ─────────────────────────

    function minNextBid(string memory label) public view returns (uint256) {
        Auction storage a = _auctions[keccak256(bytes(label))];
        if (a.highBid == 0) return reserve;
        return a.highBid + (a.highBid * minRaiseBps) / 10_000;
    }

    function bid(string calldata label) external payable nonReentrant {
        Auction storage a = _auctions[keccak256(bytes(label))];
        if (!a.exists) revert NoSuchAuction();
        if (block.timestamp < a.start || block.timestamp >= a.end || a.settled) revert NotOpen();
        if (msg.value < minNextBid(label)) revert BidTooLow();
        if (a.highBidder != address(0)) pendingReturns[a.highBidder] += a.highBid; // the previous leader gets their money back
        a.highBidder = msg.sender;
        a.highBid = msg.value;
        emit BidPlaced(label, msg.sender, msg.value, a.end);
    }

    /// @notice Anyone can finish an auction once its time is up.
    function settle(string calldata label) external nonReentrant {
        Auction storage a = _auctions[keccak256(bytes(label))];
        if (!a.exists) revert NoSuchAuction();
        if (a.settled) revert AlreadySettled();
        if (block.timestamp < a.end) revert NotEnded();
        a.settled = true;
        address winner = a.highBidder;
        if (winner == address(0)) {
            emit AuctionSettled(label, address(0), 0, false); // no bids: the name stays reserved
            return;
        }
        uint256 amount = a.highBid;
        try names.register(label, winner, termDuration) returns (uint64) {
            proceeds += amount;
            emit AuctionSettled(label, winner, amount, true);
        } catch {
            pendingReturns[winner] += amount; // could not register: the winner simply gets their money back
            emit AuctionSettled(label, winner, amount, false);
        }
    }

    // ───────────────────────── money out ─────────────────────────

    /// @notice An outbid bidder takes back their money.
    function withdraw() external nonReentrant {
        uint256 amount = pendingReturns[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingReturns[msg.sender] = 0;
        _send(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Anyone can push the finished auctions' money to the treasury.
    function sendProceeds() external nonReentrant {
        uint256 amount = proceeds;
        if (amount == 0) revert NothingToWithdraw();
        proceeds = 0;
        _send(treasury, amount);
        emit ProceedsSent(treasury, amount);
    }

    function _send(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ───────────────────────── views for the website ─────────────────────────

    function auctionOf(string calldata label) external view returns (Auction memory) {
        return _auctions[keccak256(bytes(label))];
    }

    /// @notice Every scheduled auction, in the order they were scheduled.
    function getAuctions() external view returns (string[] memory labels, Auction[] memory data) {
        uint256 n = _labels.length;
        labels = new string[](n);
        data = new Auction[](n);
        for (uint256 i; i < n; ++i) {
            labels[i] = _labels[i];
            data[i] = _auctions[keccak256(bytes(_labels[i]))];
        }
    }

    // ───────────────────────── settings (owner) ─────────────────────────

    function setSettings(uint256 reserve_, uint16 minRaiseBps_, uint256 termDuration_, address treasury_) external onlyOwner {
        if (minRaiseBps_ > MAX_RAISE_BPS || termDuration_ < 365 days || termDuration_ > 10 * 365 days || treasury_ == address(0)) {
            revert BadParam();
        }
        reserve = reserve_;
        minRaiseBps = minRaiseBps_;
        termDuration = termDuration_;
        treasury = treasury_;
        emit SettingsChanged(reserve_, minRaiseBps_, termDuration_, treasury_);
    }
}
