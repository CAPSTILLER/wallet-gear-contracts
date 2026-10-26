// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/// @title Desk Vault — GEAR float for the Gear Trade Desk.
/// @notice Holds GEAR and lets the owner (Cap's Ledger) approve the trade desk to pull payouts.
///         Repayments flow back here. "Pause" = revokeSpender(desk) (allowance to 0).
contract DeskVault is Ownable2Step, ERC721Holder, ERC1155Holder {
    using SafeERC20 for IERC20;

    IERC20 public immutable gearToken;

    error ZeroAddress();
    error InsufficientBalance();
    error EthTransferFailed();
    error RenounceDisabled();

    event SpenderApproved(address indexed spender, uint256 amount);
    event SpenderRevoked(address indexed spender);
    event GearWithdrawn(address indexed to, uint256 amount);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ERC721Rescued(address indexed nft, uint256 indexed tokenId, address indexed to);
    event ERC1155Rescued(address indexed nft, uint256 indexed id, uint256 amount, address indexed to);
    event EthRescued(address indexed to, uint256 amount);

    constructor(address owner_, address gearToken_) Ownable(owner_) {
        if (gearToken_ == address(0)) revert ZeroAddress();
        gearToken = IERC20(gearToken_);
    }

    receive() external payable {}

    // ---- Approvals (the desk pulls GEAR via allowance) ----
    function approveSpender(address spender, uint256 amount) external onlyOwner {
        if (spender == address(0)) revert ZeroAddress();
        gearToken.forceApprove(spender, amount);
        emit SpenderApproved(spender, amount);
    }

    /// @notice Emergency stop for a spender: sets its GEAR allowance to 0.
    function revokeSpender(address spender) external onlyOwner {
        if (spender == address(0)) revert ZeroAddress();
        gearToken.forceApprove(spender, 0);
        emit SpenderRevoked(spender);
    }

    // ---- Moving funds out ----
    function withdrawGear(uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        if (gearToken.balanceOf(address(this)) < amount) revert InsufficientBalance();
        gearToken.safeTransfer(to, amount);
        emit GearWithdrawn(to, amount);
    }

    function withdrawAllGear(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = gearToken.balanceOf(address(this));
        gearToken.safeTransfer(to, amount);
        emit GearWithdrawn(to, amount);
    }

    /// @notice Any ERC-20 (GEAR included) sent here.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function rescueERC721(address nft, uint256 tokenId, address to) external onlyOwner {
        if (nft == address(0) || to == address(0)) revert ZeroAddress();
        IERC721(nft).safeTransferFrom(address(this), to, tokenId);
        emit ERC721Rescued(nft, tokenId, to);
    }

    function rescueERC1155(address nft, uint256 id, uint256 amount, address to) external onlyOwner {
        if (nft == address(0) || to == address(0)) revert ZeroAddress();
        IERC1155(nft).safeTransferFrom(address(this), to, id, amount, "");
        emit ERC1155Rescued(nft, id, amount, to);
    }

    function rescueETH(address payable to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthRescued(to, amount);
    }

    // ---- Ownership: two-step via Ownable2Step (transferOwnership + acceptOwnership) ----
    /// @notice Cancel a pending ownership transfer.
    function cancelOwnershipTransfer() external onlyOwner {
        _transferOwnership(owner()); // clears pendingOwner
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    // ---- Views ----
    function gearBalance() external view returns (uint256) { return gearToken.balanceOf(address(this)); }
    function allowanceTo(address spender) external view returns (uint256) { return gearToken.allowance(address(this), spender); }
}
