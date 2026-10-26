// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

interface IWalletGear is IERC721 {
    function teethOf(uint256 tokenId) external pure returns (uint8);
}

/// @title Gear Trade Desk — offer / accept / reclaim trades and sell-to-house for Wallet Gears.
/// @notice Payout per gear = primary tooth count (11/18/32) whole GEAR, paid from the gear vault
///         via allowance. If the vault can't pay in full, offers and house sales revert (nothing moves).
contract GearTradeDesk is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_GEARS = 10;
    uint256 public constant ABANDON_AFTER = 183 days; // ~6 months
    uint256 public constant TREASURY_BPS = 1000; // 10% of reclaim repayment; 90% to vault

    enum Status { None, Open, Cancelled, Accepted, Completed, Abandoned }

    struct Offer {
        address offerer;
        address taker;
        uint64 createdAt;
        uint64 acceptedAt;
        Status status;
        uint256 paid; // GEAR paid to offerer at createOffer (what they must repay)
        uint256[] offered; // offerer's gears (escrowed until accepted)
        uint256[] received; // taker's gears (escrowed until reclaim/abandon)
    }

    IWalletGear public immutable gear;
    IERC20 public immutable gearToken;
    uint256 public immutable unit; // 10**decimals of GEAR
    address public vault;
    address public treasury;
    address public house;

    Offer[] internal _offers;
    mapping(address => uint256[]) internal _offersBy;

    event OfferCreated(uint256 indexed offerId, address indexed offerer, uint256[] tokenIds, uint256 paid);
    event OfferCancelled(uint256 indexed offerId, address indexed offerer, uint256 repaid);
    event OfferAccepted(uint256 indexed offerId, address indexed taker, uint256[] tokenIds);
    event Reclaimed(uint256 indexed offerId, address indexed offerer, uint256 toVault, uint256 toTreasury);
    event AbandonedClaimed(uint256 indexed offerId, address indexed to);
    event SoldToHouse(address indexed seller, address indexed house, uint256[] tokenIds, uint256 paid);
    event VaultSet(address vault);
    event TreasurySet(address treasury);
    event HouseSet(address house);

    error BadCount();
    error VaultCannotPay(uint256 owed, uint256 available);
    error NotOfferer();
    error WrongStatus();
    error OwnOffer();
    error ReclaimWindowClosed();
    error NotAbandonedYet();
    error ZeroAddress();
    error BadOffer();

    constructor(address owner_, address gear_, address gearToken_, address vault_, address treasury_, address house_)
        Ownable(owner_)
    {
        if (gear_ == address(0) || gearToken_ == address(0) || vault_ == address(0) || treasury_ == address(0) || house_ == address(0)) {
            revert ZeroAddress();
        }
        gear = IWalletGear(gear_);
        gearToken = IERC20(gearToken_);
        unit = 10 ** IERC20Metadata(gearToken_).decimals();
        vault = vault_;
        treasury = treasury_;
        house = house_;
    }

    // ---------------- user actions ----------------

    /// @notice Escrow 1..10 of your gears and get paid their tooth-count GEAR now from the vault.
    function createOffer(uint256[] calldata tokenIds) external whenNotPaused nonReentrant returns (uint256 offerId) {
        uint256 owed = quote(tokenIds); // also checks count
        _requireVault(owed);
        offerId = _offers.length;
        Offer storage o = _offers.push();
        o.offerer = msg.sender;
        o.createdAt = uint64(block.timestamp);
        o.status = Status.Open;
        o.paid = owed;
        o.offered = tokenIds;
        _offersBy[msg.sender].push(offerId);
        for (uint256 i; i < tokenIds.length; i++) gear.transferFrom(msg.sender, address(this), tokenIds[i]);
        gearToken.safeTransferFrom(vault, msg.sender, owed);
        emit OfferCreated(offerId, msg.sender, tokenIds, owed);
    }

    /// @notice Before anyone accepts, the offerer can repay the GEAR (100% back to vault) and take their gears back.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage o = _get(offerId);
        if (o.offerer != msg.sender) revert NotOfferer();
        if (o.status != Status.Open) revert WrongStatus();
        o.status = Status.Cancelled;
        gearToken.safeTransferFrom(msg.sender, vault, o.paid);
        _sendAll(o.offered, msg.sender);
        emit OfferCancelled(offerId, msg.sender, o.paid);
    }

    /// @notice Trade 1..10 of your gears (any mix, any count) for all of an open offer's gears.
    ///         Your gears are held by the desk until the offerer reclaims them (or they're abandoned).
    function acceptOffer(uint256 offerId, uint256[] calldata myTokenIds) external whenNotPaused nonReentrant {
        Offer storage o = _get(offerId);
        if (o.status != Status.Open) revert WrongStatus();
        if (o.offerer == msg.sender) revert OwnOffer();
        if (myTokenIds.length == 0 || myTokenIds.length > MAX_GEARS) revert BadCount();
        o.status = Status.Accepted;
        o.taker = msg.sender;
        o.acceptedAt = uint64(block.timestamp);
        o.received = myTokenIds;
        for (uint256 i; i < myTokenIds.length; i++) gear.transferFrom(msg.sender, address(this), myTokenIds[i]);
        _sendAll(o.offered, msg.sender);
        emit OfferAccepted(offerId, msg.sender, myTokenIds);
    }

    /// @notice Offerer repays the GEAR they got (90% vault / 10% treasury) and receives the traded-in gears.
    function reclaim(uint256 offerId) external nonReentrant {
        Offer storage o = _get(offerId);
        if (o.offerer != msg.sender) revert NotOfferer();
        if (o.status != Status.Accepted) revert WrongStatus();
        if (block.timestamp >= uint256(o.acceptedAt) + ABANDON_AFTER) revert ReclaimWindowClosed();
        o.status = Status.Completed;
        uint256 toTreasury = o.paid * TREASURY_BPS / 10_000;
        uint256 toVault = o.paid - toTreasury;
        gearToken.safeTransferFrom(msg.sender, vault, toVault);
        if (toTreasury > 0) gearToken.safeTransferFrom(msg.sender, treasury, toTreasury);
        _sendAll(o.received, msg.sender);
        emit Reclaimed(offerId, msg.sender, toVault, toTreasury);
    }

    /// @notice Sell 1..10 gears straight to the house for their tooth-count GEAR from the vault.
    function sellToHouse(uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        uint256 owed = quote(tokenIds);
        _requireVault(owed);
        address h = house;
        for (uint256 i; i < tokenIds.length; i++) gear.transferFrom(msg.sender, h, tokenIds[i]);
        gearToken.safeTransferFrom(vault, msg.sender, owed);
        emit SoldToHouse(msg.sender, h, tokenIds, owed);
    }

    // ---------------- owner (Cap's Ledger) ----------------

    /// @notice After 183 days without reclaim, the traded-in gears are forfeit; owner sends them to `to`.
    function claimAbandoned(uint256 offerId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        Offer storage o = _get(offerId);
        if (o.status != Status.Accepted) revert WrongStatus();
        if (block.timestamp < uint256(o.acceptedAt) + ABANDON_AFTER) revert NotAbandonedYet();
        o.status = Status.Abandoned;
        _sendAll(o.received, to);
        emit AbandonedClaimed(offerId, to);
    }

    function setVault(address v) external onlyOwner { if (v == address(0)) revert ZeroAddress(); vault = v; emit VaultSet(v); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); treasury = t; emit TreasurySet(t); }
    function setHouse(address h) external onlyOwner { if (h == address(0)) revert ZeroAddress(); house = h; emit HouseSet(h); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ---------------- views for the UI ----------------

    function payoutOf(uint256 tokenId) public view returns (uint256) { return uint256(gear.teethOf(tokenId)) * unit; }

    function quote(uint256[] calldata tokenIds) public view returns (uint256 total) {
        if (tokenIds.length == 0 || tokenIds.length > MAX_GEARS) revert BadCount();
        for (uint256 i; i < tokenIds.length; i++) total += payoutOf(tokenIds[i]);
    }

    /// @notice How much GEAR the vault can pay right now (min of balance and allowance to this desk).
    function vaultAvailable() public view returns (uint256) {
        uint256 bal = gearToken.balanceOf(vault);
        uint256 al = gearToken.allowance(vault, address(this));
        return bal < al ? bal : al;
    }

    function vaultCanPay(uint256 amount) public view returns (bool) { return vaultAvailable() >= amount; }

    function offerCount() external view returns (uint256) { return _offers.length; }

    function getOffer(uint256 offerId) external view returns (Offer memory) { return _get(offerId); }

    function getOffers(uint256 start, uint256 count) external view returns (Offer[] memory out) {
        uint256 n = _offers.length;
        if (start >= n) return out;
        uint256 end = start + count > n ? n : start + count;
        out = new Offer[](end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = _offers[i];
    }

    function offerIdsOf(address user) external view returns (uint256[] memory) { return _offersBy[user]; }

    function reclaimDeadline(uint256 offerId) external view returns (uint256) {
        Offer storage o = _get(offerId);
        return o.acceptedAt == 0 ? 0 : uint256(o.acceptedAt) + ABANDON_AFTER;
    }

    // ---------------- internal ----------------

    function _get(uint256 offerId) internal view returns (Offer storage) {
        if (offerId >= _offers.length) revert BadOffer();
        return _offers[offerId];
    }

    function _requireVault(uint256 owed) internal view {
        uint256 avail = vaultAvailable();
        if (avail < owed) revert VaultCannotPay(owed, avail);
    }

    function _sendAll(uint256[] storage ids, address to) internal {
        for (uint256 i; i < ids.length; i++) gear.transferFrom(address(this), to, ids[i]);
    }
}
