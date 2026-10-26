# Wallet Gear v3 contracts (Base)

Two contracts, both owned by Cap's Ledger `0xD8382719b8fF90eE3Dd521B9d7c5dc23E8e4EAca` (Ownable2Step).

| Contract | What it does |
|---|---|
| `WalletGear` (ERC-721 "WGEAR") | One gear per wallet, ever. `tokenId = uint256(uint160(minter))`, so traits stay tied to the minter forever. `mint()` pulls exactly **1 USDC** (owner-settable) straight to the gear treasury. `teethOf(id)` = primary tooth count 11/18/32, identical to `traits3.js` (tested on 512 addresses). `tokenURI = baseURI + tokenId`. Owner: pause, price, treasury, baseURI. |
| `GearTradeDesk` | Trade offers, reclaim, abandonment, sell-to-house. Payout per gear = `teethOf` whole GEAR from the gear vault. Refuses any offer/sale the vault can't fully pay (balance **and** allowance) — automatic pause, nothing moves. |

Addresses: Base USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` · GEAR `0x5880cD05605A549f1DAb01a53ca61Ee559244bD1` (6 decimals) · gear vault `0x41ca72E18f7F96F8F2b7be524AC8346e06bCB3AB` · gear treasury `0xCF1ac98565DA846E8263604b49C1276Ed78A0981`.

## Trade desk flow
1. **createOffer(ids)** — 1–10 gears go into the desk; offerer is paid sum(teeth) GEAR from the vault right away.
2. **cancelOffer(id)** — before anyone accepts, offerer repays that GEAR (100% back to vault) and gets their gears back.
3. **acceptOffer(id, myIds)** — anyone else puts in 1–10 of their gears (any count/mix); the desk holds them and they receive all the offer's gears. Taker is not paid GEAR.
4. **reclaim(id)** — offerer repays the GEAR they got (90% vault / 10% treasury) and receives the taker's gears. Trade complete.
5. **claimAbandoned(id, to)** — 183 days after acceptance with no reclaim, owner sends the taker's gears to `to` (treasury or Cap).
6. **sellToHouse(ids)** — 1–10 gears go straight to `house` (defaults to the Ledger, settable); seller gets payout from vault.

Owner pause blocks createOffer / acceptOffer / sellToHouse only; cancel and reclaim always work so nobody gets stuck.
UI views: `quote`, `payoutOf`, `vaultAvailable`, `vaultCanPay`, `offerCount`, `getOffer`, `getOffers(start,count)`, `offerIdsOf`, `reclaimDeadline`.

## Deploy + setup (Bankr / Cap) — 5 steps
1. **Deploy both** (deployer wallet, Base): `BASE_URI=ipfs://<metadataCID>/ forge script script/Deploy.s.sol --rpc-url https://mainnet.base.org --broadcast --account <deployer>` (prints both addresses; deployer key is never in this repo).
2. **Ledger accepts ownership**: from `0xD838…EAca` call `acceptOwnership()` on WalletGear and on GearTradeDesk.
3. **Vault approves desk**: from the gear vault call GEAR `approve(<GearTradeDesk>, <amount>)` (one signature; revocable).
4. **Set baseURI** (if not set at deploy, or when metadata moves): Ledger calls `WalletGear.setBaseURI("ipfs://<CID>/")`. Metadata file name = decimal tokenId.
5. **Fund the vault with GEAR** and do a test: mint one gear (approve 1 USDC to WalletGear, then `mint()`), check treasury got 1 USDC.

## Dev
```
forge install --no-git OpenZeppelin/openzeppelin-contracts@v5.1.0 foundry-rs/forge-std
forge test
node fixtures/gen.mjs > fixtures/teeth.json   # regenerate traits3.js fixture
```
