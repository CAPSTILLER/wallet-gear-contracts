# Wallet Gear v3 contracts (Base)

Two contracts, both owned by Cap's Ledger `0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca` (Ownable2Step).

| Contract | What it does |
|---|---|
| `WalletGear` (ERC-721 "WGEAR") | One gear per wallet, ever. `tokenId = uint256(uint160(minter))`, so traits stay tied to the minter forever. `mint()` pulls exactly **1 USDC** (owner-settable) straight to the gear treasury. `teethOf(id)` = primary tooth count 11/18/32, identical to `traits3.js` (tested on 512 addresses). `tokenURI = baseURI + tokenId`. Owner: pause, price, treasury, baseURI. |
| `GearTradeDesk` | Offers with many bids, one-tx finalize, two-section bin (abandoned + purchased), sell-to-house. Payout per gear = `teethOf` whole GEAR from the gear vault. Refuses any offer, bid or sale the vault can't fully pay (balance **and** allowance). That works as an automatic pause, and nothing moves. |

Addresses: Base USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` · GEAR `0x5880cD05605A549f1DAb01a53ca61Ee559244bD1` (6 decimals) · gear vault `0x41ca72E18f7F96F8F2b7be524AC8346e06bCB3AB` · gear treasury `0xCF1ac98565DA846E8263604b49C1276Ed78A0981`.

## Trade rules in plain words
1. **Make an offer** (`createOffer`): put 1–10 gears in the desk. You're paid their tooth count in GEAR (11/18/32 each) from the vault right away.
2. **Bid** (`placeBid`): anyone except the offerer can bid 1–10 of their own gears on an open offer, and there's no limit on how many bids an offer can get. Each bidder's gears are held, and they're paid their tooth-count GEAR right away.
3. **Pull out with no penalty:** before the trade is finalized, the offerer can `cancelOffer` and any bidder can `withdrawBid`. Either one pays back exactly the GEAR they got (100% to the vault) and gets their gears back.
4. **Finalize** (`acceptBid`, offerer only): the offerer picks one bid and pays back their GEAR in the same transaction (90% vault / 10% treasury). Their gears go to that bidder, the bidder's gears go to the offerer, and the trade is done. The winning bidder keeps the GEAR they were paid. This doesn't loop over other bids, so gas stays flat no matter how many bids there are.
5. **Losing bids:** after a finalize or cancel, the other bidders have 183 days to withdraw (repaying 100% to the vault). The clock starts at the finalize or cancel time, which is always later than the bid itself, so it's the more generous choice for bidders.
6. **12-month limit:** an offer that isn't finalized within 365 days of when it was **created** is abandoned. Late bids don't extend that deadline. Before then, the offerer can cancel and bidders can withdraw. At the deadline, the offerer's gears and every open bid on that offer go into the bin.
7. **Bin, abandoned section** (`buyFromBin`): anyone, including Cap, can buy any abandoned gear at face value: 32, 18 or 11 GEAR. Bin status is worked out automatically, so nobody has to sweep. The owner has no special way to take users' gears.
8. **Sell to house + bin, purchased section** (`sellToHouse`, `buyPurchased`): a user sells 1–10 gears for their tooth-count GEAR from the vault. The gears stay in the desk, listed in the purchased section. Anyone can buy them at fixed prices: 32T = **35 GEAR**, 18T = **20**, 11T = **12** (constants). There is no house wallet.
**Fixed 90/10 split:** every GEAR-for-gear payment (finalize repay, abandoned buy, purchased buy) goes 90% vault / 10% treasury (constant `TREASURY_BPS`, not changeable). Cancel and bid-withdraw repayments go 100% to the vault.
**No gear NFT ever goes to the treasury, the owner or any house wallet.** Gears only move between users and the desk.

9. **Pause** blocks new offers, bids, finalizes, house sales and both kinds of bin purchase. Cancels and bid withdrawals always work.

UI views: `quote`, `payoutOf`, `vaultAvailable`, `vaultCanPay`, `offerCount`, `bidCount`, `getOffer`, `getBid`, `getOffers(start,count)`, `getBidsForOffer(offerId,start,count)`, `offerIdsOf`, `bidIdsOf`, `offerExpiry`, `bidDeadline`, `inBin`, `binTokens(bidStart,count)`, `binTokensFromOffers(offerStart,count)` (abandoned section); `purchasedCount`, `purchasedTokens(start,count)`, `purchasedPriceOf`, `purchasedIndex` (purchased section).

## Deploy + setup (Bankr / Cap) — 5 steps
1. **Deploy both** (deployer wallet, Base): `BASE_URI=ipfs://<metadataCID>/ forge script script/Deploy.s.sol --rpc-url https://mainnet.base.org --broadcast --account <deployer>` (prints both addresses; deployer key is never in this repo).
2. **Ledger accepts ownership**: from `0xD838…EAca` call `acceptOwnership()` on WalletGear and on GearTradeDesk.
3. **Vault approves desk**: from the gear vault call GEAR `approve(<GearTradeDesk>, <amount>)` (one signature; revocable). Users must also approve GEAR to the desk before cancel/withdraw/finalize/bin buys (the UI asks once).
4. **Set baseURI** (if not set at deploy, or when metadata moves): Ledger calls `WalletGear.setBaseURI("ipfs://<CID>/")`. Metadata file name = decimal tokenId.
5. **Fund the vault with GEAR** and do a test: mint one gear (approve 1 USDC to WalletGear, then `mint()`), check treasury got 1 USDC.

## Dev
```
forge install --no-git OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std
forge test
node fixtures/gen.mjs > fixtures/teeth.json   # regenerate traits3.js fixture
```

## Desk Vault (GEAR float for the Trade Desk)

`src/DeskVault.sol` — GearVault can't give the desk an allowance, so the desk pays from a DeskVault instead.
Owned by the Ledger (Ownable2Step, renounce disabled). Repayments (90%) flow back into it.

Owner functions: `approveSpender(spender, amount)`, `revokeSpender(spender)` (emergency stop),
`withdrawGear(amount, to)`, `withdrawAllGear(to)`, `rescueToken(token, amount, to)`,
`rescueERC721(nft, tokenId, to)`, `rescueERC1155(nft, id, amount, to)`, `rescueETH(to)`,
`transferOwnership(newOwner)` / `acceptOwnership()` / `cancelOwnershipTransfer()`.
Views: `gearBalance()`, `allowanceTo(spender)`.

Deploy (owner = Ledger, gear = GEAR, Base):
`forge script script/DeployDeskVault.s.sol:DeployDeskVault --rpc-url base --broadcast --verify`

Ledger steps after deploy:
1. GearVault `0x41ca72E18f7F96F8F2b7be524AC8346e06bCB3AB`: `withdrawGear(amount, deskVault)`
2. DeskVault: `approveSpender(0x6B05415f46F7aDde0b9B343726257EBe34757374, amount or max)`
3. GearTradeDesk `0x6B05415f46F7aDde0b9B343726257EBe34757374`: `setVault(deskVault)`
