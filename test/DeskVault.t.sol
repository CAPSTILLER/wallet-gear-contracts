// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Test.sol";
import {DeskVault} from "../src/DeskVault.sol";
import {Mock6} from "./Mocks.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract N721 is ERC721("N", "N") { function mint(address t, uint256 i) external { _mint(t, i); } }
contract N1155 is ERC1155("") { function mint(address t, uint256 i, uint256 a) external { _mint(t, i, a, ""); } }

contract DeskVaultTest is Test {
    DeskVault v; Mock6 gear; Mock6 other;
    address owner = address(0xA11CE); address bob = address(0xB0B); address desk = address(0xDE5C);

    function setUp() public {
        gear = new Mock6("G"); other = new Mock6("G");
        v = new DeskVault(owner, address(gear));
        gear.mint(address(v), 1_000e6);
    }

    function test_ctor() public view { assertEq(v.owner(), owner); assertEq(address(v.gearToken()), address(gear)); assertEq(v.gearBalance(), 1_000e6); }
    function test_ctorZero() public { vm.expectRevert(DeskVault.ZeroAddress.selector); new DeskVault(owner, address(0)); }

    function test_approveAndPull() public {
        vm.prank(owner); v.approveSpender(desk, 500e6);
        assertEq(v.allowanceTo(desk), 500e6);
        vm.prank(desk); gear.transferFrom(address(v), bob, 200e6);
        assertEq(gear.balanceOf(bob), 200e6);
        vm.prank(owner); v.approveSpender(desk, type(uint256).max);
        assertEq(v.allowanceTo(desk), type(uint256).max);
    }
    function test_revoke() public {
        vm.startPrank(owner); v.approveSpender(desk, 500e6); v.revokeSpender(desk); vm.stopPrank();
        assertEq(v.allowanceTo(desk), 0);
        vm.prank(desk); vm.expectRevert(); gear.transferFrom(address(v), bob, 1);
    }
    function test_withdraw() public {
        vm.prank(owner); v.withdrawGear(300e6, bob); assertEq(gear.balanceOf(bob), 300e6);
        vm.prank(owner); vm.expectRevert(DeskVault.InsufficientBalance.selector); v.withdrawGear(701e6, bob);
        vm.prank(owner); v.withdrawAllGear(bob); assertEq(gear.balanceOf(bob), 1_000e6); assertEq(v.gearBalance(), 0);
    }
    function test_rescueTokens() public {
        other.mint(address(v), 5); vm.prank(owner); v.rescueToken(address(other), 5, bob); assertEq(other.balanceOf(bob), 5);
        vm.prank(owner); v.rescueToken(address(gear), 7, bob); assertEq(gear.balanceOf(bob), 7);
    }
    function test_rescueNFTs() public {
        N721 n = new N721(); n.mint(address(this), 1); n.safeTransferFrom(address(this), address(v), 1);
        vm.prank(owner); v.rescueERC721(address(n), 1, bob); assertEq(n.ownerOf(1), bob);
        N1155 m = new N1155(); m.mint(address(v), 3, 10);
        vm.prank(owner); v.rescueERC1155(address(m), 3, 10, bob); assertEq(m.balanceOf(bob, 3), 10);
    }
    function test_rescueETH() public {
        vm.deal(address(this), 1 ether); (bool ok,) = address(v).call{value: 1 ether}(""); assertTrue(ok);
        vm.prank(owner); v.rescueETH(payable(bob)); assertEq(bob.balance, 1 ether);
    }
    function test_zeroAddrs() public {
        vm.startPrank(owner);
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.approveSpender(address(0), 1);
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.revokeSpender(address(0));
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.withdrawGear(1, address(0));
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.withdrawAllGear(address(0));
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.rescueToken(address(0), 1, bob);
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.rescueToken(address(gear), 1, address(0));
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.rescueERC721(address(0), 1, bob);
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.rescueERC1155(address(0), 1, 1, bob);
        vm.expectRevert(DeskVault.ZeroAddress.selector); v.rescueETH(payable(address(0)));
        vm.stopPrank();
    }
    function test_onlyOwner() public {
        bytes memory e = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob);
        vm.startPrank(bob);
        vm.expectRevert(e); v.approveSpender(desk, 1);
        vm.expectRevert(e); v.revokeSpender(desk);
        vm.expectRevert(e); v.withdrawGear(1, bob);
        vm.expectRevert(e); v.withdrawAllGear(bob);
        vm.expectRevert(e); v.rescueToken(address(gear), 1, bob);
        vm.expectRevert(e); v.rescueERC721(address(gear), 1, bob);
        vm.expectRevert(e); v.rescueERC1155(address(gear), 1, 1, bob);
        vm.expectRevert(e); v.rescueETH(payable(bob));
        vm.expectRevert(e); v.transferOwnership(bob);
        vm.expectRevert(e); v.cancelOwnershipTransfer();
        vm.expectRevert(e); v.renounceOwnership();
        vm.stopPrank();
    }
    function test_twoStepOwnership() public {
        vm.prank(owner); v.transferOwnership(bob);
        assertEq(v.owner(), owner); assertEq(v.pendingOwner(), bob);
        vm.prank(desk); vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, desk)); v.acceptOwnership();
        vm.prank(bob); v.acceptOwnership();
        assertEq(v.owner(), bob); assertEq(v.pendingOwner(), address(0));
    }
    function test_cancelOwnership() public {
        vm.startPrank(owner); v.transferOwnership(bob); v.cancelOwnershipTransfer(); vm.stopPrank();
        assertEq(v.pendingOwner(), address(0)); assertEq(v.owner(), owner);
        vm.prank(bob); vm.expectRevert(); v.acceptOwnership();
    }
    function test_renounceDisabled() public { vm.prank(owner); vm.expectRevert(DeskVault.RenounceDisabled.selector); v.renounceOwnership(); }
}

interface ILiveDesk {
    function owner() external view returns (address);
    function setVault(address) external;
    function vault() external view returns (address);
    function vaultAvailable() external view returns (uint256);
    function vaultCanPay(uint256) external view returns (bool);
}

/// Base mainnet fork against the live GearTradeDesk. Skips if no RPC.
contract DeskVaultForkTest is Test {
    address constant LEDGER = 0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca;
    address constant GEAR = 0x5880cD05605A549f1DAb01a53ca61Ee559244bD1;
    address constant DESK = 0x6B05415f46F7aDde0b9B343726257EBe34757374;
    address constant OLD_VAULT = 0x41ca72E18f7F96F8F2b7be524AC8346e06bCB3AB;

    function test_fork_livedeskPaysFromDeskVault() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        try vm.createSelectFork(rpc) {} catch { vm.skip(true); }
        ILiveDesk d = ILiveDesk(DESK);
        assertEq(d.owner(), LEDGER);
        assertEq(d.vaultAvailable(), 0); // today: GearVault can't approve

        DeskVault v = new DeskVault(LEDGER, GEAR);
        // Step 1 (simulated): GearVault.withdrawGear(amount, deskVault) by Ledger
        uint256 amt = 10_000e6;
        vm.prank(LEDGER); (bool ok,) = OLD_VAULT.call(abi.encodeWithSignature("withdrawGear(uint256,address)", amt, address(v)));
        if (!ok || IERC20(GEAR).balanceOf(address(v)) < amt) deal(GEAR, address(v), amt);
        // Step 2
        vm.prank(LEDGER); v.approveSpender(DESK, type(uint256).max);
        // Step 3
        vm.prank(LEDGER); d.setVault(address(v));
        assertEq(d.vault(), address(v));
        assertEq(d.vaultAvailable(), amt);
        assertTrue(d.vaultCanPay(amt));
        // Desk pull works (as in sellToHouse / putUp payouts)
        address user = address(0xBEEF);
        vm.prank(DESK); IERC20(GEAR).transferFrom(address(v), user, 32e6);
        assertEq(IERC20(GEAR).balanceOf(user), 32e6);
        assertEq(d.vaultAvailable(), amt - 32e6);
        // Emergency stop
        vm.prank(LEDGER); v.revokeSpender(DESK);
        assertEq(d.vaultAvailable(), 0);
    }
}
