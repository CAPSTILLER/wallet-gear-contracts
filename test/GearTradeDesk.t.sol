// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import "forge-std/Test.sol";
import {WalletGear} from "../src/WalletGear.sol";
import {GearTradeDesk} from "../src/GearTradeDesk.sol";
import {Mock6, HookToken} from "./Mocks.sol";

contract DeskTest is Test {
    WalletGear g; Mock6 usdc; Mock6 gt; GearTradeDesk d;
    address constant LEDGER = 0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca;
    address constant TREASURY = 0xCF1ac98565DA846E8263604b49C1276Ed78A0981;
    address constant VAULT = 0x41ca72E18f7F96F8F2b7be524AC8346e06bCB3AB;
    address alice = address(0xA11CE); address bob = address(0xB0B);

    function setUp() public {
        usdc = new Mock6("USDC"); gt = new Mock6("GEAR");
        g = new WalletGear(LEDGER, address(usdc), TREASURY, 1e6, "");
        d = new GearTradeDesk(LEDGER, address(g), address(gt), VAULT, TREASURY, LEDGER);
        gt.mint(VAULT, 1_000_000e6);
        vm.prank(VAULT); gt.approve(address(d), type(uint256).max);
    }

    /// mint gears from fresh wallets n and hand them to `to`
    function _gears(address to, uint256 n, uint256 salt) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; i++) {
            address m = address(uint160(uint256(keccak256(abi.encode(salt, i)))));
            usdc.mint(m, 1e6);
            vm.startPrank(m); usdc.approve(address(g), 1e6); ids[i] = g.mint(); g.transferFrom(m, to, ids[i]); vm.stopPrank();
        }
        vm.prank(to); g.setApprovalForAll(address(d), true);
    }

    function _sumTeeth(uint256[] memory ids) internal view returns (uint256 s) { for (uint256 i; i < ids.length; i++) s += g.teethOf(ids[i]); }

    function test_fullTradeLifecycle() public {
        uint256[] memory a = _gears(alice, 3, 1);
        uint256[] memory b = _gears(bob, 2, 2);
        uint256 owed = _sumTeeth(a) * 1e6;
        assertEq(d.quote(a), owed);
        vm.prank(alice); uint256 id = d.createOffer(a);
        assertEq(gt.balanceOf(alice), owed);
        for (uint256 i; i < 3; i++) assertEq(g.ownerOf(a[i]), address(d));

        vm.prank(bob); d.acceptOffer(id, b);
        for (uint256 i; i < 3; i++) assertEq(g.ownerOf(a[i]), bob);
        for (uint256 i; i < 2; i++) assertEq(g.ownerOf(b[i]), address(d));
        assertEq(gt.balanceOf(bob), 0);

        uint256 vaultBefore = gt.balanceOf(VAULT);
        vm.startPrank(alice); gt.approve(address(d), owed); d.reclaim(id); vm.stopPrank();
        for (uint256 i; i < 2; i++) assertEq(g.ownerOf(b[i]), alice);
        assertEq(gt.balanceOf(TREASURY), owed / 10);
        assertEq(gt.balanceOf(VAULT) - vaultBefore, owed - owed / 10);
        assertEq(uint8(d.getOffer(id).status), uint8(GearTradeDesk.Status.Completed));
    }

    function test_cancelBeforeAccept() public {
        uint256[] memory a = _gears(alice, 2, 3);
        uint256 v0 = gt.balanceOf(VAULT);
        vm.startPrank(alice); uint256 id = d.createOffer(a);
        gt.approve(address(d), type(uint256).max); d.cancelOffer(id); vm.stopPrank();
        assertEq(g.ownerOf(a[0]), alice); assertEq(gt.balanceOf(VAULT), v0); assertEq(gt.balanceOf(alice), 0);
        vm.prank(bob); vm.expectRevert(GearTradeDesk.WrongStatus.selector); d.acceptOffer(id, a);
    }

    function test_cannotAcceptOwnOrTwice() public {
        uint256[] memory a = _gears(alice, 1, 4); uint256[] memory a2 = _gears(alice, 1, 5);
        uint256[] memory b = _gears(bob, 1, 6);
        vm.prank(alice); uint256 id = d.createOffer(a);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.OwnOffer.selector); d.acceptOffer(id, a2);
        vm.prank(bob); d.acceptOffer(id, b);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.WrongStatus.selector); d.acceptOffer(id, a2);
        vm.prank(bob); vm.expectRevert(GearTradeDesk.NotOfferer.selector); d.reclaim(id);
    }

    function test_tenGearLimit() public {
        uint256[] memory a = _gears(alice, 11, 7);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.BadCount.selector); d.createOffer(a);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.BadCount.selector); d.sellToHouse(a);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.BadCount.selector); d.createOffer(none);
        uint256[] memory ten = new uint256[](10); for (uint256 i; i < 10; i++) ten[i] = a[i];
        vm.prank(alice); d.createOffer(ten);
        assertEq(g.balanceOf(address(d)), 10);
    }

    function test_duplicateIdsRevert() public {
        uint256[] memory a = _gears(alice, 1, 8);
        uint256[] memory dup = new uint256[](2); dup[0] = a[0]; dup[1] = a[0];
        vm.prank(alice); vm.expectRevert(); d.createOffer(dup);
    }

    function test_abandonmentTiming() public {
        uint256[] memory a = _gears(alice, 1, 9); uint256[] memory b = _gears(bob, 1, 10);
        vm.prank(alice); uint256 id = d.createOffer(a);
        vm.prank(bob); d.acceptOffer(id, b);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 183 days - 1);
        vm.prank(LEDGER); vm.expectRevert(GearTradeDesk.NotAbandonedYet.selector); d.claimAbandoned(id, TREASURY);
        vm.warp(t0 + 183 days);
        vm.startPrank(alice); gt.approve(address(d), type(uint256).max);
        vm.expectRevert(GearTradeDesk.ReclaimWindowClosed.selector); d.reclaim(id); vm.stopPrank();
        vm.prank(bob); vm.expectRevert(); d.claimAbandoned(id, bob);
        vm.prank(LEDGER); d.claimAbandoned(id, TREASURY);
        assertEq(g.ownerOf(b[0]), TREASURY);
        vm.prank(LEDGER); vm.expectRevert(GearTradeDesk.WrongStatus.selector); d.claimAbandoned(id, TREASURY);
    }

    function test_reclaimJustBeforeDeadline() public {
        uint256[] memory a = _gears(alice, 1, 11); uint256[] memory b = _gears(bob, 1, 12);
        vm.prank(alice); uint256 id = d.createOffer(a);
        vm.prank(bob); d.acceptOffer(id, b);
        vm.warp(block.timestamp + 183 days - 1);
        vm.startPrank(alice); gt.approve(address(d), type(uint256).max); d.reclaim(id); vm.stopPrank();
        assertEq(g.ownerOf(b[0]), alice);
    }

    function test_vaultInsufficientBalanceReverts() public {
        uint256[] memory a = _gears(alice, 2, 13);
        uint256 bal = gt.balanceOf(VAULT);
        vm.prank(VAULT); gt.transfer(address(1), bal - 1e6);
        assertFalse(d.vaultCanPay(d.quote(a)));
        vm.prank(alice); vm.expectRevert(); d.createOffer(a);
        vm.prank(alice); vm.expectRevert(); d.sellToHouse(a);
        assertEq(g.ownerOf(a[0]), alice); assertEq(gt.balanceOf(alice), 0);
        gt.mint(VAULT, 1000e6); // topped up -> works again automatically
        vm.prank(alice); d.createOffer(a);
    }

    function test_vaultInsufficientAllowanceReverts() public {
        uint256[] memory a = _gears(alice, 1, 14);
        vm.prank(VAULT); gt.approve(address(d), 5e6);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(GearTradeDesk.VaultCannotPay.selector, uint256(g.teethOf(a[0])) * 1e6, 5e6));
        d.createOffer(a);
    }

    function test_sellToHouse() public {
        uint256[] memory a = _gears(alice, 4, 15);
        vm.prank(alice); d.sellToHouse(a);
        for (uint256 i; i < 4; i++) assertEq(g.ownerOf(a[i]), LEDGER);
        assertEq(gt.balanceOf(alice), _sumTeeth(a) * 1e6);
        vm.prank(LEDGER); d.setHouse(TREASURY);
        uint256[] memory b = _gears(bob, 1, 16);
        vm.prank(bob); d.sellToHouse(b);
        assertEq(g.ownerOf(b[0]), TREASURY);
    }

    function test_pauseBlocksNewButNotReclaim() public {
        uint256[] memory a = _gears(alice, 1, 17); uint256[] memory b = _gears(bob, 1, 18);
        vm.prank(alice); uint256 id = d.createOffer(a);
        vm.prank(bob); d.acceptOffer(id, b);
        vm.prank(LEDGER); d.pause();
        uint256[] memory c = _gears(alice, 1, 19);
        vm.prank(alice); vm.expectRevert(); d.createOffer(c);
        vm.prank(alice); vm.expectRevert(); d.sellToHouse(c);
        vm.startPrank(alice); gt.approve(address(d), type(uint256).max); d.reclaim(id); vm.stopPrank();
    }

    function test_cannotTakeOthersGears() public {
        uint256[] memory a = _gears(alice, 1, 20);
        vm.prank(bob); vm.expectRevert(); d.createOffer(a);
        vm.prank(bob); vm.expectRevert(); d.sellToHouse(a);
    }

    function test_views() public {
        uint256[] memory a = _gears(alice, 2, 21);
        vm.prank(alice); d.createOffer(a);
        assertEq(d.offerCount(), 1);
        assertEq(d.offerIdsOf(alice).length, 1);
        assertEq(d.getOffers(0, 50).length, 1);
        assertEq(d.getOffers(5, 50).length, 0);
        assertEq(d.reclaimDeadline(0), 0);
    }

    function testFuzz_reclaimSplit(uint8 n) public {
        n = uint8(bound(n, 1, 10));
        uint256[] memory a = _gears(alice, n, 100 + n); uint256[] memory b = _gears(bob, 1, 200 + n);
        vm.prank(alice); uint256 id = d.createOffer(a);
        uint256 owed = gt.balanceOf(alice);
        assertEq(owed, _sumTeeth(a) * 1e6);
        vm.prank(bob); d.acceptOffer(id, b);
        uint256 v0 = gt.balanceOf(VAULT);
        vm.startPrank(alice); gt.approve(address(d), owed); d.reclaim(id); vm.stopPrank();
        assertEq(gt.balanceOf(TREASURY) + gt.balanceOf(VAULT) - v0, owed);
        assertEq(gt.balanceOf(alice), 0);
    }

    function test_reentrancyBlocked() public {
        HookToken h = new HookToken();
        GearTradeDesk d2 = new GearTradeDesk(LEDGER, address(g), address(h), VAULT, TREASURY, LEDGER);
        h.mint(VAULT, 1000e6);
        vm.prank(VAULT); h.approve(address(d2), type(uint256).max);
        uint256[] memory a = _gears(alice, 1, 30);
        vm.prank(alice); g.setApprovalForAll(address(d2), true);
        h.arm(address(d2));
        vm.prank(alice); d2.createOffer(a);
        assertTrue(h.reentered()); assertTrue(h.reentryReverted());
        assertEq(h.balanceOf(alice), uint256(g.teethOf(a[0])) * 1e6);
    }
}
