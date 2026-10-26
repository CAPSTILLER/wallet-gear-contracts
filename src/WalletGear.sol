// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title Wallet Gear v3 — one fixed gear per wallet, forever.
/// @notice tokenId = uint256(uint160(minter)). Traits are derived off-chain (traits3.js)
///         from keccak256(minter address); only the primary gear tooth count is ported on-chain.
contract WalletGear is ERC721, Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    IERC20 public immutable usdc;
    address public treasury;
    uint256 public mintPrice; // USDC base units (6 decimals) — 1 USDC = 1_000_000
    string public baseURI;
    uint256 public totalMinted;

    event Minted(address indexed minter, uint256 indexed tokenId, uint8 teeth, uint256 price);
    event MintPriceSet(uint256 price);
    event TreasurySet(address treasury);
    event BaseURISet(string uri);

    error AlreadyMinted();
    error ZeroAddress();
    error NotAWalletId();

    constructor(address owner_, address usdc_, address treasury_, uint256 price_, string memory baseURI_)
        ERC721("Wallet Gear", "WGEAR")
        Ownable(owner_)
    {
        if (usdc_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        usdc = IERC20(usdc_);
        treasury = treasury_;
        mintPrice = price_;
        baseURI = baseURI_;
    }

    /// @notice Mint your wallet's gear. Pays `mintPrice` USDC straight to the treasury (approve USDC first).
    function mint() external whenNotPaused nonReentrant returns (uint256 tokenId) {
        tokenId = uint256(uint160(msg.sender));
        if (_ownerOf(tokenId) != address(0)) revert AlreadyMinted(); // no burn exists, so minted once = forever
        totalMinted++;
        _mint(msg.sender, tokenId); // effects before the external USDC pull
        if (mintPrice > 0) usdc.safeTransferFrom(msg.sender, treasury, mintPrice);
        emit Minted(msg.sender, tokenId, teethOf(tokenId), mintPrice);
    }

    function hasMinted(address wallet) external view returns (bool) {
        return _ownerOf(uint256(uint160(wallet))) != address(0);
    }

    function minterOf(uint256 tokenId) external pure returns (address) {
        if (tokenId >> 160 != 0) revert NotAWalletId();
        return address(uint160(tokenId));
    }

    /// @notice Primary gear tooth count (11/18/32), identical to traits3.js:
    ///   H1 = keccak256(20 address bytes); tier = pick(u(H1,0)); Prophet (top 70/10000) => 32;
    ///   else teeth = pick(u(H1,2), [[32,40],[18,35],[11,25]]).
    function teethOf(uint256 tokenId) public pure returns (uint8) {
        if (tokenId >> 160 != 0) revert NotAWalletId();
        bytes32 h = keccak256(abi.encodePacked(address(uint160(tokenId))));
        uint256 tierV = (uint256(uint8(h[0])) << 8) | uint8(h[1]);
        if (tierV * 10000 >= 9930 * 65536) return 32; // Prophet
        uint256 v = ((uint256(uint8(h[2])) << 8) | uint8(h[3])) * 100;
        if (v < 40 * 65536) return 32;
        if (v < 75 * 65536) return 18;
        return 11;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return bytes(baseURI).length == 0 ? "" : string.concat(baseURI, tokenId.toString());
    }

    // ---- owner (Cap's Ledger) ----
    function setMintPrice(uint256 p) external onlyOwner { mintPrice = p; emit MintPriceSet(p); }
    function setTreasury(address t) external onlyOwner { if (t == address(0)) revert ZeroAddress(); treasury = t; emit TreasurySet(t); }
    function setBaseURI(string calldata u) external onlyOwner { baseURI = u; emit BaseURISet(u); }
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
