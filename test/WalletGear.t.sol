// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Test.sol";
import {WalletGear} from "../src/WalletGear.sol";
import {Mock6} from "./Mocks.sol";

contract WalletGearTest is Test {
    WalletGear g; Mock6 usdc;
    address constant LEDGER = 0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca;
    address constant TREASURY = 0xCF1ac98565DA846E8263604b49C1276Ed78A0981;
    address alice = address(0xA11CE);

    function setUp() public {
        usdc = new Mock6("USDC");
        g = new WalletGear(LEDGER, address(usdc), TREASURY, 1e6, "ipfs://CID/");
    }

    function _fund(address a) internal { usdc.mint(a, 10e6); vm.prank(a); usdc.approve(address(g), type(uint256).max); }

    function test_mintPays1UsdcToTreasury() public {
        _fund(alice);
        vm.prank(alice); uint256 id = g.mint();
        assertEq(id, uint256(uint160(alice)));
        assertEq(g.ownerOf(id), alice);
        assertEq(usdc.balanceOf(TREASURY), 1e6);
        assertEq(usdc.balanceOf(alice), 9e6);
        assertEq(g.tokenURI(id), string.concat("ipfs://CID/", vm.toString(id)));
        assertTrue(g.hasMinted(alice));
    }

    function test_onePerWalletEvenAfterTransfer() public {
        _fund(alice);
        vm.startPrank(alice); g.mint();
        vm.expectRevert(WalletGear.AlreadyMinted.selector); g.mint();
        g.transferFrom(alice, address(0xB0B), uint256(uint160(alice)));
        vm.expectRevert(WalletGear.AlreadyMinted.selector); g.mint();
        vm.stopPrank();
        assertEq(usdc.balanceOf(TREASURY), 1e6);
    }

    function test_mintNeedsUsdc() public {
        vm.prank(alice); vm.expectRevert(); g.mint();
    }

    function test_ownerControls() public {
        vm.expectRevert(); g.pause();
        vm.prank(LEDGER); g.pause();
        _fund(alice); vm.prank(alice); vm.expectRevert(); g.mint();
        vm.startPrank(LEDGER); g.unpause(); g.setMintPrice(2e6); g.setBaseURI("ipfs://X/"); vm.stopPrank();
        vm.prank(alice); g.mint();
        assertEq(usdc.balanceOf(TREASURY), 2e6);
    }

    function test_ownable2Step() public {
        WalletGear g2 = new WalletGear(address(this), address(usdc), TREASURY, 1e6, "");
        g2.transferOwnership(LEDGER);
        assertEq(g2.owner(), address(this));
        vm.prank(LEDGER); g2.acceptOwnership();
        assertEq(g2.owner(), LEDGER);
    }

    function test_teethMatchesTraits3js() public view {
        string memory j = vm.readFile("fixtures/teeth.json");
        address[] memory a = vm.parseJsonAddressArray(j, ".addrs");
        uint256[] memory t = vm.parseJsonUintArray(j, ".teeth");
        assertEq(a.length, 512);
        for (uint256 i; i < a.length; i++) assertEq(g.teethOf(uint256(uint160(a[i]))), t[i]);
    }

    function testFuzz_teethInSet(address a) public view {
        uint8 t = g.teethOf(uint256(uint160(a)));
        assertTrue(t == 11 || t == 18 || t == 32);
    }

    function test_teethRejectsNonWalletId() public {
        vm.expectRevert(WalletGear.NotAWalletId.selector); g.teethOf(1 << 160);
    }
}
