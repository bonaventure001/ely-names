// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/// @title ElyNames
/// @notice Registry + registrar + resolver + reverse records for `.ely` names, in one contract.
///         Every name is an ERC-721 with an expiry. Only approved controllers can register/renew.
contract ElyNames is ERC721, Ownable2Step {
    uint64 public constant GRACE_PERIOD = 90 days;
    uint256 public constant MIN_LABEL_LENGTH = 2;
    uint256 public constant MAX_LABEL_LENGTH = 63;

    mapping(address => bool) public controllers;
    mapping(uint256 => uint64) public expiries;
    mapping(uint256 => string) public labelOf;

    // Records live under a "version" that bumps on every mint/transfer, so a new owner
    // never inherits the old owner's address or text records.
    mapping(uint256 => uint256) private _version;
    mapping(uint256 => mapping(uint256 => address)) private _addrs;
    mapping(uint256 => mapping(uint256 => mapping(string => string))) private _texts;

    mapping(address => uint256) private _primary; // token id, 0 = none

    event ControllerSet(address indexed controller, bool allowed);
    event NameRegistered(uint256 indexed id, string label, address indexed owner, uint64 expires);
    event NameRenewed(uint256 indexed id, string label, uint64 expires);
    event AddrChanged(uint256 indexed id, address addr);
    event TextChanged(uint256 indexed id, string key, string value);
    event PrimaryNameSet(address indexed account, uint256 indexed id);

    error NotController();
    error InvalidLabel();
    error NameUnavailable();
    error NameExpired();
    error NotNameOwner();
    error TooLateToRenew();

    constructor(address initialOwner) ERC721("Ely Names", "ELY") Ownable(initialOwner) {}

    // ───────────────────────── admin ─────────────────────────

    function setController(address controller, bool allowed) external onlyOwner {
        controllers[controller] = allowed;
        emit ControllerSet(controller, allowed);
    }

    // ───────────────────────── views ─────────────────────────

    function idOf(string memory label) public pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    function isValidLabel(string memory label) public pure returns (bool) {
        bytes memory b = bytes(label);
        uint256 n = b.length;
        if (n < MIN_LABEL_LENGTH || n > MAX_LABEL_LENGTH) return false;
        if (b[0] == 0x2d || b[n - 1] == 0x2d) return false; // no leading/trailing hyphen
        for (uint256 i; i < n; ++i) {
            bytes1 c = b[i];
            bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x2d; // a-z 0-9 -
            if (!ok) return false;
        }
        return true;
    }

    /// @notice True if the label can be registered right now (never registered, or past expiry + grace).
    function available(string memory label) public view returns (bool) {
        return isValidLabel(label) && uint256(expiries[idOf(label)]) + GRACE_PERIOD < block.timestamp;
    }

    function nameExpires(string memory label) external view returns (uint256) {
        return expiries[idOf(label)];
    }

    /// @dev Reverts for expired names, like ENS.
    function ownerOf(uint256 tokenId) public view override returns (address) {
        if (expiries[tokenId] <= block.timestamp) revert NameExpired();
        return super.ownerOf(tokenId);
    }

    // ───────────────────── controller actions ─────────────────────

    function register(string calldata label, address owner, uint256 duration) external returns (uint64 expires) {
        if (!controllers[msg.sender]) revert NotController();
        if (!isValidLabel(label)) revert InvalidLabel();
        uint256 id = idOf(label);
        if (uint256(expiries[id]) + GRACE_PERIOD >= block.timestamp) revert NameUnavailable();

        if (_ownerOf(id) != address(0)) _burn(id); // clear the expired previous owner
        labelOf[id] = label;
        expires = uint64(block.timestamp + duration);
        expiries[id] = expires;
        _mint(owner, id);
        emit NameRegistered(id, label, owner, expires);
    }

    function renew(string calldata label, uint256 duration) external returns (uint64 expires) {
        if (!controllers[msg.sender]) revert NotController();
        uint256 id = idOf(label);
        if (uint256(expiries[id]) + GRACE_PERIOD < block.timestamp || expiries[id] == 0) revert TooLateToRenew();
        expires = uint64(uint256(expiries[id]) + duration);
        expiries[id] = expires;
        emit NameRenewed(id, label, expires);
    }

    // ───────────────────────── records ─────────────────────────

    modifier onlyNameOwner(uint256 id) {
        address owner = ownerOf(id); // reverts if expired
        if (!_isAuthorized(owner, msg.sender, id)) revert NotNameOwner();
        _;
    }

    function setAddr(uint256 id, address a) external onlyNameOwner(id) {
        _addrs[id][_version[id]] = a;
        emit AddrChanged(id, a);
    }

    function setText(uint256 id, string calldata key, string calldata value) external onlyNameOwner(id) {
        _texts[id][_version[id]][key] = value;
        emit TextChanged(id, key, value);
    }

    /// @notice Resolve `label.ely` to an address. Returns address(0) if unregistered or expired.
    function resolve(string calldata label) external view returns (address) {
        uint256 id = idOf(label);
        if (expiries[id] <= block.timestamp) return address(0);
        return _addrs[id][_version[id]];
    }

    function text(string calldata label, string calldata key) external view returns (string memory) {
        uint256 id = idOf(label);
        if (expiries[id] <= block.timestamp) return "";
        return _texts[id][_version[id]][key];
    }

    // ───────────────────── primary (reverse) name ─────────────────────

    function setPrimaryName(uint256 id) external {
        if (ownerOf(id) != msg.sender) revert NotNameOwner();
        _primary[msg.sender] = id;
        emit PrimaryNameSet(msg.sender, id);
    }

    function clearPrimaryName() external {
        delete _primary[msg.sender];
        emit PrimaryNameSet(msg.sender, 0);
    }

    /// @notice The `.ely` name an address has chosen, or "" if none / expired / no longer owned.
    function primaryNameOf(address account) external view returns (string memory) {
        uint256 id = _primary[account];
        if (id == 0 || expiries[id] <= block.timestamp || _ownerOf(id) != account) return "";
        return string.concat(labelOf[id], ".ely");
    }

    // ───────────────────────── metadata ─────────────────────────

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        string memory full = string.concat(labelOf[tokenId], ".ely");
        string memory svg = string.concat(
            "<svg xmlns='http://www.w3.org/2000/svg' width='500' height='500'>",
            "<rect width='500' height='500' fill='#04181C'/>",
            "<text x='250' y='260' font-family='monospace' font-size='36' fill='#97FCE4' text-anchor='middle'>",
            full,
            "</text></svg>"
        );
        string memory json = string.concat(
            '{"name":"', full, '","description":"A .ely name on Elysium","image":"data:image/svg+xml;base64,',
            Base64.encode(bytes(svg)), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ───────────────────────── internals ─────────────────────────

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        // Mint and burn are always allowed; transferring an expired name is not.
        if (from != address(0) && to != address(0) && expiries[tokenId] <= block.timestamp) revert NameExpired();
        if (to != address(0)) {
            // Fresh records for every new owner: address defaults to the new owner.
            uint256 v = ++_version[tokenId];
            _addrs[tokenId][v] = to;
        }
        return super._update(to, tokenId, auth);
    }
}
