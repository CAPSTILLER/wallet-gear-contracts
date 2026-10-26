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

/// @title Gear Trade Desk v2 — offers with many bids, one-tx finalize, abandoned bin, sell-to-house.
/// @notice Every gear put up (offer or bid) is paid its primary tooth count in whole GEAR from the vault
///         immediately. Pulling out before finalization = repay 100% to vault. The offerer finalizes by
///         picking a bid AND repaying their GEAR (90% vault / 10% treasury) in one tx: gears swap, done.
///         Losing bids stay withdrawable 183 days after finalize/cancel; offers not finalized within
///         365 days of creation are abandoned (offer gears + open bids). Leftovers land in the abandoned bin, buyable by anyone at face value
///         (teeth GEAR). Bin status is computed lazily — no sweeping needed.
contract GearTradeDesk is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_GEARS = 10;
    uint256 public constant CLAIM_WINDOW = 183 days; // ~6 months: losing bids after finalize, bids after cancel
    uint256 public constant OFFER_LIFETIME = 365 days; // 12 months from creation to finalize, else abandoned
    uint256 public constant FINALIZE_TREASURY_BPS = 1000; // offerer repayment on finalize: 10% treasury, 90% vault

    enum OfferStatus { None, Open, Cancelled, Finalized }
    enum BidStatus { None, Open, Withdrawn, Won }

    struct Offer {
        address offerer;
        uint64 createdAt;
        uint64 closedAt; // cancel time or finalize time
        OfferStatus status;
        uint256 paid; // GEAR paid to offerer (what they repay)
        uint256 winningBid; // valid when Finalized
        uint256[] gears;
        uint256[] bidIds;
    }

    struct Bid {
        uint256 offerId;
        address taker;
        uint64 createdAt;
        BidStatus status;
        uint256 paid; // GEAR paid to taker (what they repay to withdraw)
        uint256[] gears;
    }

    IWalletGear public immutable gear;
    IERC20 public immutable gearToken;
    uint256 public immutable unit; // 10**decimals of GEAR
    address public vault;
    address public treasury;
    address public house;
    uint256 public binTreasuryBps = 1000; // bin purchase split: 10% treasury, 90% vault (owner-settable)

    Offer[] internal _offers;
    Bid[] internal _bids;
    mapping(address => uint256[]) internal _offersBy;
    mapping(address => uint256[]) internal _bidsBy;
    /// tokenId => bidId+1 while a bid's gear is held by the desk (0 = not held in a bid)
    mapping(uint256 => uint256) public heldInBid;
    /// tokenId => offerId+1 while an open offer's gear is held by the desk
    mapping(uint256 => uint256) public heldInOffer;

    event OfferCreated(uint256 indexed offerId, address indexed offerer, uint256[] tokenIds, uint256 paid);
    event OfferCancelled(uint256 indexed offerId, address indexed offerer, uint256 repaid);
    event BidPlaced(uint256 indexed offerId, uint256 indexed bidId, address indexed taker, uint256[] tokenIds, uint256 paid);
    event BidWithdrawn(uint256 indexed offerId, uint256 indexed bidId, address indexed taker, uint256 repaid);
    event BidAccepted(uint256 indexed offerId, uint256 indexed bidId, address indexed taker);
    event Finalized(uint256 indexed offerId, uint256 indexed bidId, address indexed taker, uint256 toVault, uint256 toTreasury);
    event BinPurchase(address indexed buyer, uint256 indexed tokenId, uint256 toVault, uint256 toTreasury);
    event SoldToHouse(address indexed seller, address indexed house, uint256[] tokenIds, uint256 paid);
    event VaultSet(address indexed vault);
    event TreasurySet(address indexed treasury);
    event HouseSet(address indexed house);
    event BinTreasuryBpsSet(uint256 bps);

    error BadCount();
    error VaultCannotPay(uint256 owed, uint256 available);
    error NotOfferer();
    error NotTaker();
    error WrongStatus();
    error OwnOffer();
    error WindowClosed();
    error NotInBin();
    error ZeroAddress();
    error BadId();
    error BidNotOnOffer();
    error BadBps();
    error HouseIsTreasury();

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
        if (house_ == treasury_) revert HouseIsTreasury();
        house = house_;
    }

    // ================= offerer =================

    /// @notice Escrow 1..10 gears; get paid sum(teeth) GEAR from the vault now.
    function createOffer(uint256[] calldata tokenIds) external whenNotPaused nonReentrant returns (uint256 offerId) {
        uint256 owed = quote(tokenIds);
        _requireVault(owed);
        offerId = _offers.length;
        Offer storage o = _offers.push();
        o.offerer = msg.sender;
        o.createdAt = uint64(block.timestamp);
        o.status = OfferStatus.Open;
        o.paid = owed;
        o.gears = tokenIds;
        _offersBy[msg.sender].push(offerId);
        for (uint256 i; i < tokenIds.length; i++) heldInOffer[tokenIds[i]] = offerId + 1;
        _pullGears(tokenIds, msg.sender, address(this));
        gearToken.safeTransferFrom(vault, msg.sender, owed);
        emit OfferCreated(offerId, msg.sender, tokenIds, owed);
    }

    /// @notice Pull out before finalization: repay 100% to vault, get your gears back.
    ///         Open bids stay withdrawable by their takers for CLAIM_WINDOW from now.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage o = _offer(offerId);
        if (o.offerer != msg.sender) revert NotOfferer();
        if (o.status != OfferStatus.Open) revert WrongStatus();
        if (block.timestamp >= offerExpiry(offerId)) revert WindowClosed();
        o.status = OfferStatus.Cancelled;
        o.closedAt = uint64(block.timestamp);
        _clearOffer(o.gears);
        gearToken.safeTransferFrom(msg.sender, vault, o.paid);
        _sendGears(o.gears, msg.sender);
        emit OfferCancelled(offerId, msg.sender, o.paid);
    }

    /// @notice Finalize (offerer only): pick one open bid and repay the GEAR you got (90% vault / 10% treasury)
    ///         in this same tx. Your gears go to that taker, their gears come to you. The taker keeps their GEAR.
    function acceptBid(uint256 offerId, uint256 bidId) external whenNotPaused nonReentrant {
        Offer storage o = _offer(offerId);
        if (o.offerer != msg.sender) revert NotOfferer();
        if (o.status != OfferStatus.Open) revert WrongStatus();
        if (block.timestamp >= offerExpiry(offerId)) revert WindowClosed();
        Bid storage b = _bid(bidId);
        if (b.offerId != offerId) revert BidNotOnOffer();
        if (b.status != BidStatus.Open) revert WrongStatus();
        o.status = OfferStatus.Finalized;
        o.closedAt = uint64(block.timestamp);
        o.winningBid = bidId;
        b.status = BidStatus.Won;
        _clearOffer(o.gears);
        uint256[] storage won = b.gears;
        for (uint256 i; i < won.length; i++) delete heldInBid[won[i]];
        uint256 toTreasury = o.paid * FINALIZE_TREASURY_BPS / 10_000;
        uint256 toVault = o.paid - toTreasury;
        gearToken.safeTransferFrom(msg.sender, vault, toVault);
        if (toTreasury > 0) gearToken.safeTransferFrom(msg.sender, treasury, toTreasury);
        _sendGears(o.gears, b.taker);
        _sendGears(won, msg.sender);
        emit Finalized(offerId, bidId, b.taker, toVault, toTreasury);
    }

    // ================= takers =================

    /// @notice Bid on an open offer with 1..10 of your gears; get paid sum(teeth) GEAR from the vault now.
    function placeBid(uint256 offerId, uint256[] calldata tokenIds) external whenNotPaused nonReentrant returns (uint256 bidId) {
        Offer storage o = _offer(offerId);
        if (o.status != OfferStatus.Open) revert WrongStatus();
        if (o.offerer == msg.sender) revert OwnOffer();
        if (block.timestamp >= offerExpiry(offerId)) revert WindowClosed();
        uint256 owed = quote(tokenIds);
        _requireVault(owed);
        bidId = _bids.length;
        Bid storage b = _bids.push();
        b.offerId = offerId;
        b.taker = msg.sender;
        b.createdAt = uint64(block.timestamp);
        b.status = BidStatus.Open;
        b.paid = owed;
        b.gears = tokenIds;
        o.bidIds.push(bidId);
        _bidsBy[msg.sender].push(bidId);
        for (uint256 i; i < tokenIds.length; i++) heldInBid[tokenIds[i]] = bidId + 1;
        _pullGears(tokenIds, msg.sender, address(this));
        gearToken.safeTransferFrom(vault, msg.sender, owed);
        emit BidPlaced(offerId, bidId, msg.sender, tokenIds, owed);
    }

    /// @notice Pull your (non-winning) bid: repay 100% to vault, get your gears back.
    ///         Anytime while the offer is open (until 365 days after offer creation); within 183 days after finalize/cancel.
    function withdrawBid(uint256 bidId) external nonReentrant {
        Bid storage b = _bid(bidId);
        if (b.taker != msg.sender) revert NotTaker();
        if (b.status != BidStatus.Open) revert WrongStatus();
        if (block.timestamp >= bidDeadline(bidId)) revert WindowClosed();
        b.status = BidStatus.Withdrawn;
        uint256[] storage ids = b.gears;
        for (uint256 i; i < ids.length; i++) delete heldInBid[ids[i]];
        gearToken.safeTransferFrom(msg.sender, vault, b.paid);
        _sendGears(ids, msg.sender);
        emit BidWithdrawn(b.offerId, bidId, msg.sender, b.paid);
    }

    // ================= abandoned bin =================

    /// @notice Buy one abandoned gear for face value (teeth GEAR). Split: binTreasuryBps to treasury, rest to vault.
    function buyFromBin(uint256 tokenId) external whenNotPaused nonReentrant {
        if (!inBin(tokenId)) revert NotInBin();
        delete heldInBid[tokenId];
        delete heldInOffer[tokenId];
        uint256 price = payoutOf(tokenId);
        uint256 toTreasury = price * binTreasuryBps / 10_000;
        uint256 toVault = price - toTreasury;
        gearToken.safeTransferFrom(msg.sender, vault, toVault);
        if (toTreasury > 0) gearToken.safeTransferFrom(msg.sender, treasury, toTreasury);
        gear.transferFrom(address(this), msg.sender, tokenId);
        emit BinPurchase(msg.sender, tokenId, toVault, toTreasury);
    }

    // ================= house =================

    /// @notice Sell 1..10 gears straight to the house for their tooth-count GEAR from the vault.
    function sellToHouse(uint256[] calldata tokenIds) external whenNotPaused nonReentrant {
        uint256 owed = quote(tokenIds);
        _requireVault(owed);
        address h = house;
        _pullGears(tokenIds, msg.sender, h);
        gearToken.safeTransferFrom(vault, msg.sender, owed);
        emit SoldToHouse(msg.sender, h, tokenIds, owed);
    }

    // ================= owner =================

    function setVault(address v) external onlyOwner { if (v == address(0)) revert ZeroAddress(); vault = v; emit VaultSet(v); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); if (t == house) revert HouseIsTreasury(); treasury = t; emit TreasurySet(t); }
    function setHouse(address h) external onlyOwner { if (h == address(0)) revert ZeroAddress(); if (h == treasury) revert HouseIsTreasury(); house = h; emit HouseSet(h); }
    function setBinTreasuryBps(uint256 bps) external onlyOwner { if (bps > 10_000) revert BadBps(); binTreasuryBps = bps; emit BinTreasuryBpsSet(bps); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ================= views =================

    function payoutOf(uint256 tokenId) public view returns (uint256) { return uint256(gear.teethOf(tokenId)) * unit; }

    function quote(uint256[] calldata tokenIds) public view returns (uint256 total) {
        if (tokenIds.length == 0 || tokenIds.length > MAX_GEARS) revert BadCount();
        for (uint256 i; i < tokenIds.length; i++) total += payoutOf(tokenIds[i]);
    }

    function vaultAvailable() public view returns (uint256) {
        uint256 bal = gearToken.balanceOf(vault);
        uint256 al = gearToken.allowance(vault, address(this));
        return bal < al ? bal : al;
    }

    function vaultCanPay(uint256 amount) public view returns (bool) { return vaultAvailable() >= amount; }

    /// @notice While Open: offer expires (exclusive) 365 days after creation (bids don't extend it).
    ///         After that the offerer can't finalize/cancel and its gears + open bids are bin-eligible.
    ///         Returns 0 if the offer is no longer Open.
    function offerExpiry(uint256 offerId) public view returns (uint256) {
        Offer storage o = _offer(offerId);
        return o.status == OfferStatus.Open ? uint256(o.createdAt) + OFFER_LIFETIME : 0;
    }

    /// @notice When a non-winning bid's gears fall into the bin (exclusive). Open offer: offer creation + 365d.
    ///         Finalized/cancelled offer: closedAt + 183d (closedAt >= bid time, so the more generous choice).
    function bidDeadline(uint256 bidId) public view returns (uint256) {
        Offer storage o = _offers[_bid(bidId).offerId];
        return o.status == OfferStatus.Open ? uint256(o.createdAt) + OFFER_LIFETIME : uint256(o.closedAt) + CLAIM_WINDOW;
    }

    function inBin(uint256 tokenId) public view returns (bool) {
        uint256 h = heldInBid[tokenId];
        if (h != 0) {
            Bid storage b = _bids[h - 1];
            return b.status == BidStatus.Open && block.timestamp >= bidDeadline(h - 1);
        }
        h = heldInOffer[tokenId];
        if (h != 0) {
            Offer storage o = _offers[h - 1];
            return o.status == OfferStatus.Open && block.timestamp >= uint256(o.createdAt) + OFFER_LIFETIME;
        }
        return false;
    }

    function offerCount() external view returns (uint256) { return _offers.length; }
    function bidCount() external view returns (uint256) { return _bids.length; }
    function getOffer(uint256 offerId) external view returns (Offer memory) { return _offer(offerId); }
    function getBid(uint256 bidId) external view returns (Bid memory) { return _bid(bidId); }
    function offerIdsOf(address user) external view returns (uint256[] memory) { return _offersBy[user]; }
    function bidIdsOf(address user) external view returns (uint256[] memory) { return _bidsBy[user]; }

    function getOffers(uint256 start, uint256 count) external view returns (Offer[] memory out) {
        uint256 n = _offers.length;
        if (start >= n) return out;
        uint256 end = start + count > n ? n : start + count;
        out = new Offer[](end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = _offers[i];
    }

    /// @notice Paged bids on one offer.
    function getBidsForOffer(uint256 offerId, uint256 start, uint256 count) external view returns (Bid[] memory out) {
        uint256[] storage ids = _offer(offerId).bidIds;
        uint256 n = ids.length;
        if (start >= n) return out;
        uint256 end = start + count > n ? n : start + count;
        out = new Bid[](end - start);
        for (uint256 i = start; i < end; i++) out[i - start] = _bids[ids[i]];
    }

    /// @notice Bin gears among offers [start, start+count). Page through all offers to list the whole bin.
    function binTokensFromOffers(uint256 start, uint256 count) external view returns (uint256[] memory out, uint256 found) {
        uint256 n = _offers.length;
        uint256 end = start >= n ? start : (start + count > n ? n : start + count);
        out = new uint256[]((end - start) * MAX_GEARS);
        for (uint256 i = start; i < end; i++) {
            uint256[] storage g = _offers[i].gears;
            for (uint256 k; k < g.length; k++) if (inBin(g[k])) out[found++] = g[k];
        }
        assembly { mstore(out, found) }
    }

    /// @notice Bin gears among bids [start, start+count). Page through all bids to list the whole bin.
    function binTokens(uint256 start, uint256 count) external view returns (uint256[] memory out, uint256 found) {
        uint256 n = _bids.length;
        uint256 end = start >= n ? start : (start + count > n ? n : start + count);
        out = new uint256[]((end - start) * MAX_GEARS);
        for (uint256 i = start; i < end; i++) {
            uint256[] storage g = _bids[i].gears;
            for (uint256 k; k < g.length; k++) if (inBin(g[k])) out[found++] = g[k];
        }
        assembly { mstore(out, found) }
    }

    // ================= internal =================

    function _offer(uint256 id) internal view returns (Offer storage) { if (id >= _offers.length) revert BadId(); return _offers[id]; }
    function _bid(uint256 id) internal view returns (Bid storage) { if (id >= _bids.length) revert BadId(); return _bids[id]; }

    function _clearOffer(uint256[] storage ids) internal {
        for (uint256 i; i < ids.length; i++) delete heldInOffer[ids[i]];
    }

    function _requireVault(uint256 owed) internal view {
        uint256 avail = vaultAvailable();
        if (avail < owed) revert VaultCannotPay(owed, avail);
    }

    function _pullGears(uint256[] calldata ids, address from, address to) internal {
        for (uint256 i; i < ids.length; i++) gear.transferFrom(from, to, ids[i]);
    }

    function _sendGears(uint256[] storage ids, address to) internal {
        for (uint256 i; i < ids.length; i++) gear.transferFrom(address(this), to, ids[i]);
    }
}
