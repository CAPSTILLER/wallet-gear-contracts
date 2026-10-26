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
    address alice = address(0xA11CE); address bob = address(0xB0B); address carol = address(0xCA401); address dave = address(0xDA7E);

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

    uint256 constant W = 183 days;

    function _offer(uint256 n, uint256 salt) internal returns (uint256 id, uint256[] memory a) {
        a = _gears(alice, n, salt); vm.prank(alice); id = d.createOffer(a);
    }
    function _bid(address who, uint256 offerId, uint256 n, uint256 salt) internal returns (uint256 bid, uint256[] memory b) {
        b = _gears(who, n, salt); vm.prank(who); bid = d.placeBid(offerId, b);
    }
    function _approveAll(address who) internal { vm.prank(who); gt.approve(address(d), type(uint256).max); }

    function test_multiBidFinalizeOneTx() public {
        (uint256 id, uint256[] memory a) = _offer(3, 1);
        uint256 owed = _sumTeeth(a) * 1e6;
        assertEq(gt.balanceOf(alice), owed);
        (uint256 b1, uint256[] memory g1) = _bid(bob, id, 2, 2);
        (uint256 b2, uint256[] memory g2) = _bid(carol, id, 4, 3);
        assertEq(gt.balanceOf(bob), _sumTeeth(g1) * 1e6);
        assertEq(gt.balanceOf(carol), _sumTeeth(g2) * 1e6);
        assertEq(d.getBidsForOffer(id, 0, 10).length, 2);
        // only offerer may finalize
        _approveAll(bob);
        vm.prank(bob); vm.expectRevert(GearTradeDesk.NotOfferer.selector); d.acceptBid(id, b2);
        vm.prank(LEDGER); vm.expectRevert(GearTradeDesk.NotOfferer.selector); d.acceptBid(id, b2);
        // needs repayment in same tx
        vm.prank(alice); vm.expectRevert(); d.acceptBid(id, b2);
        _approveAll(alice);
        uint256 v0 = gt.balanceOf(VAULT); uint256 carolGear = gt.balanceOf(carol);
        vm.prank(alice); d.acceptBid(id, b2);
        for (uint256 i; i < 3; i++) assertEq(g.ownerOf(a[i]), carol);
        for (uint256 i; i < 4; i++) assertEq(g.ownerOf(g2[i]), alice);
        assertEq(gt.balanceOf(alice), 0);
        assertEq(gt.balanceOf(TREASURY), owed / 10);
        assertEq(gt.balanceOf(VAULT) - v0, owed - owed / 10);
        assertEq(gt.balanceOf(carol), carolGear); // winner keeps GEAR
        // losing bid still withdrawable, 100% to vault
        vm.prank(bob); d.withdrawBid(b1);
        assertEq(g.ownerOf(g1[0]), bob); assertEq(gt.balanceOf(bob), 0);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.WrongStatus.selector); d.acceptBid(id, b1);
        vm.prank(carol); vm.expectRevert(GearTradeDesk.WrongStatus.selector); d.withdrawBid(b2);
    }

    function test_withdrawBidWhileOpen() public {
        (uint256 id,) = _offer(1, 4);
        (uint256 b1, uint256[] memory g1) = _bid(bob, id, 2, 5);
        uint256 v0 = gt.balanceOf(VAULT);
        vm.prank(carol); vm.expectRevert(GearTradeDesk.NotTaker.selector); d.withdrawBid(b1);
        _approveAll(bob); vm.prank(bob); d.withdrawBid(b1);
        assertEq(g.ownerOf(g1[1]), bob); assertEq(gt.balanceOf(VAULT) - v0, _sumTeeth(g1) * 1e6);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.WrongStatus.selector); d.acceptBid(id, b1);
    }

    function test_cancelWithOpenBids() public {
        (uint256 id, uint256[] memory a) = _offer(2, 6);
        (uint256 b1, uint256[] memory g1) = _bid(bob, id, 1, 7);
        uint256 v0 = gt.balanceOf(VAULT);
        _approveAll(alice); vm.prank(alice); d.cancelOffer(id);
        assertEq(g.ownerOf(a[0]), alice); assertEq(gt.balanceOf(VAULT) - v0, _sumTeeth(a) * 1e6);
        (, uint256[] memory x) = (0, _gears(carol, 1, 8));
        vm.prank(carol); vm.expectRevert(GearTradeDesk.WrongStatus.selector); d.placeBid(id, x);
        uint256 t0 = block.timestamp;
        assertEq(d.bidDeadline(b1), t0 + W);
        vm.warp(t0 + W - 1);
        assertFalse(d.inBin(g1[0]));
        _approveAll(bob); vm.prank(bob); d.withdrawBid(b1);
        assertEq(g.ownerOf(g1[0]), bob);
    }

    function test_cancelledOfferBidGoesToBinAtBoundary() public {
        (uint256 id,) = _offer(1, 9);
        (uint256 b1, uint256[] memory g1) = _bid(bob, id, 1, 10);
        vm.warp(block.timestamp + 50 days);
        _approveAll(alice); vm.prank(alice); d.cancelOffer(id);
        uint256 t0 = block.timestamp; // deadline measured from cancel (later than bid => more generous)
        vm.warp(t0 + W);
        assertTrue(d.inBin(g1[0]));
        _approveAll(bob); vm.prank(bob); vm.expectRevert(GearTradeDesk.WindowClosed.selector); d.withdrawBid(b1);
    }

    function test_losingBidBoundaryAndBinPurchase() public {
        (uint256 id,) = _offer(1, 11);
        (uint256 bw,) = _bid(bob, id, 1, 12);
        (uint256 bl, uint256[] memory gl) = _bid(carol, id, 3, 13);
        _approveAll(alice); vm.prank(alice); d.acceptBid(id, bw);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + W - 1);
        assertFalse(d.inBin(gl[0]));
        vm.prank(dave); vm.expectRevert(GearTradeDesk.NotInBin.selector); d.buyFromBin(gl[0]);
        vm.warp(t0 + W);
        assertTrue(d.inBin(gl[0]));
        _approveAll(carol); vm.prank(carol); vm.expectRevert(GearTradeDesk.WindowClosed.selector); d.withdrawBid(bl);
        (uint256[] memory bin, uint256 n) = d.binTokens(0, 10);
        assertEq(n, 3); assertEq(bin.length, 3);
        uint256 price = uint256(g.teethOf(gl[0])) * 1e6;
        gt.mint(dave, 1000e6); _approveAll(dave);
        uint256 v0 = gt.balanceOf(VAULT); uint256 tr0 = gt.balanceOf(TREASURY);
        vm.prank(dave); d.buyFromBin(gl[0]);
        assertEq(g.ownerOf(gl[0]), dave);
        assertEq(gt.balanceOf(TREASURY) - tr0, price / 10);
        assertEq(gt.balanceOf(VAULT) - v0, price - price / 10);
        assertFalse(d.inBin(gl[0]));
        vm.prank(dave); vm.expectRevert(GearTradeDesk.NotInBin.selector); d.buyFromBin(gl[0]);
        // owner-settable split
        vm.prank(LEDGER); d.setBinTreasuryBps(5000);
        vm.prank(LEDGER); vm.expectRevert(GearTradeDesk.BadBps.selector); d.setBinTreasuryBps(10001);
        uint256 p2 = uint256(g.teethOf(gl[1])) * 1e6; tr0 = gt.balanceOf(TREASURY);
        vm.prank(dave); d.buyFromBin(gl[1]);
        assertEq(gt.balanceOf(TREASURY) - tr0, p2 / 2);
    }

    function test_idleOfferExpiry() public {
        (uint256 id, uint256[] memory a) = _offer(2, 14);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 100 days);
        (uint256 b1, uint256[] memory g1) = _bid(bob, id, 1, 15); // bid refreshes the clock
        uint256 t1 = block.timestamp;
        assertEq(d.offerExpiry(id), t1 + W);
        vm.warp(t1 + W - 1);
        assertFalse(d.inBin(a[0]));
        vm.warp(t1 + W);
        assertTrue(d.inBin(a[0])); assertTrue(d.inBin(g1[0]));
        _approveAll(alice);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.WindowClosed.selector); d.cancelOffer(id);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.WindowClosed.selector); d.acceptBid(id, b1);
        uint256[] memory x = _gears(carol, 1, 16);
        vm.prank(carol); vm.expectRevert(GearTradeDesk.WindowClosed.selector); d.placeBid(id, x);
        (, uint256 n) = d.binTokensFromOffers(0, 10); assertEq(n, 2);
        gt.mint(dave, 1000e6); _approveAll(dave);
        vm.startPrank(dave); d.buyFromBin(a[0]); d.buyFromBin(g1[0]); vm.stopPrank();
        assertEq(g.ownerOf(a[0]), dave); assertEq(g.ownerOf(g1[0]), dave);
    }

    function test_cannotBidOwnOffer() public {
        (uint256 id,) = _offer(1, 17);
        uint256[] memory x = _gears(alice, 1, 18);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.OwnOffer.selector); d.placeBid(id, x);
    }

    function test_bidOnWrongOffer() public {
        (uint256 id1,) = _offer(1, 19);
        (uint256 id2,) = _offer(1, 20);
        (uint256 b,) = _bid(bob, id2, 1, 21);
        _approveAll(alice); vm.prank(alice); vm.expectRevert(GearTradeDesk.BidNotOnOffer.selector); d.acceptBid(id1, b);
    }

    function test_manyBidsFinalizeGasConstant() public {
        (uint256 id,) = _offer(1, 22);
        (uint256 first,) = _bid(bob, id, 1, 23);
        for (uint256 i; i < 60; i++) _bid(address(uint160(0x1000 + i)), id, 1, 1000 + i);
        _approveAll(alice);
        uint256 g0 = gasleft(); vm.prank(alice); d.acceptBid(id, first); uint256 used = g0 - gasleft();
        assertLt(used, 250_000); // no loop over all bids
        assertEq(d.getBidsForOffer(id, 0, 100).length, 61);
    }

    function test_tenGearLimit() public {
        uint256[] memory a = _gears(alice, 11, 7);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.BadCount.selector); d.createOffer(a);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.BadCount.selector); d.sellToHouse(a);
        uint256[] memory none = new uint256[](0);
        vm.prank(alice); vm.expectRevert(GearTradeDesk.BadCount.selector); d.createOffer(none);
        uint256[] memory ten = new uint256[](10); for (uint256 i; i < 10; i++) ten[i] = a[i];
        vm.prank(alice); uint256 oid = d.createOffer(ten);
        uint256[] memory b11 = _gears(bob, 11, 77);
        vm.prank(bob); vm.expectRevert(GearTradeDesk.BadCount.selector); d.placeBid(oid, b11);
        assertEq(g.balanceOf(address(d)), 10);
    }

    function test_duplicateIdsRevert() public {
        uint256[] memory a = _gears(alice, 1, 8);
        uint256[] memory dup = new uint256[](2); dup[0] = a[0]; dup[1] = a[0];
        vm.prank(alice); vm.expectRevert(); d.createOffer(dup);
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
        vm.prank(alice); uint256 id = d.createOffer(a);
        uint256[] memory b = _gears(bob, 1, 99);
        bal = gt.balanceOf(VAULT);
        vm.prank(VAULT); gt.transfer(address(1), bal);
        vm.prank(bob); vm.expectRevert(); d.placeBid(id, b);
        assertEq(g.ownerOf(b[0]), bob); assertEq(gt.balanceOf(bob), 0);
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

    function test_pauseBlocksNewButNotWithdrawals() public {
        (uint256 id,) = _offer(1, 40);
        (uint256 b1,) = _bid(bob, id, 1, 41);
        (uint256 id2,) = _offer(1, 42);
        vm.prank(LEDGER); d.pause();
        uint256[] memory c = _gears(carol, 1, 43);
        vm.prank(carol); vm.expectRevert(); d.createOffer(c);
        vm.prank(carol); vm.expectRevert(); d.placeBid(id, c);
        vm.prank(carol); vm.expectRevert(); d.sellToHouse(c);
        _approveAll(alice); vm.prank(alice); vm.expectRevert(); d.acceptBid(id, b1);
        vm.prank(carol); vm.expectRevert(); d.buyFromBin(c[0]);
        _approveAll(bob); vm.prank(bob); d.withdrawBid(b1);
        vm.prank(alice); d.cancelOffer(id2);
    }

    function test_cannotTakeOthersGears() public {
        uint256[] memory a = _gears(alice, 1, 20);
        vm.prank(bob); vm.expectRevert(); d.createOffer(a);
        vm.prank(bob); vm.expectRevert(); d.sellToHouse(a);
    }

    function test_views() public {
        (uint256 id,) = _offer(2, 50);
        _bid(bob, id, 1, 51);
        assertEq(d.offerCount(), 1); assertEq(d.bidCount(), 1);
        assertEq(d.offerIdsOf(alice).length, 1); assertEq(d.bidIdsOf(bob).length, 1);
        assertEq(d.getOffers(0, 50).length, 1); assertEq(d.getOffers(5, 50).length, 0);
        assertEq(d.getBidsForOffer(id, 3, 5).length, 0);
        assertEq(d.getBid(0).offerId, id);
        vm.expectRevert(GearTradeDesk.BadId.selector); d.getOffer(9);
    }

    function testFuzz_finalizeSplitAndConservation(uint8 n, uint8 m) public {
        n = uint8(bound(n, 1, 10)); m = uint8(bound(m, 1, 10));
        (uint256 id, uint256[] memory a) = _offer(n, 300 + n);
        (uint256 b,) = _bid(bob, id, m, 400 + m);
        uint256 owed = gt.balanceOf(alice);
        assertEq(owed, _sumTeeth(a) * 1e6);
        uint256 supply = gt.balanceOf(VAULT) + gt.balanceOf(TREASURY) + gt.balanceOf(alice) + gt.balanceOf(bob);
        _approveAll(alice); vm.prank(alice); d.acceptBid(id, b);
        assertEq(gt.balanceOf(alice), 0);
        assertEq(gt.balanceOf(TREASURY), owed / 10);
        assertEq(gt.balanceOf(VAULT) + gt.balanceOf(TREASURY) + gt.balanceOf(bob), supply);
        assertEq(g.balanceOf(address(d)), 0);
    }

    function testFuzz_withdrawRestores(uint8 m, uint32 dt) public {
        m = uint8(bound(m, 1, 10));
        (uint256 id,) = _offer(1, 500);
        (uint256 b,) = _bid(bob, id, m, 600 + m);
        uint256 v0 = gt.balanceOf(VAULT);
        vm.warp(block.timestamp + bound(dt, 0, W - 1));
        _approveAll(bob); vm.prank(bob); d.withdrawBid(b);
        assertEq(g.balanceOf(bob), m); assertEq(gt.balanceOf(bob), 0);
        assertEq(gt.balanceOf(VAULT) - v0 > 0, true);
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
