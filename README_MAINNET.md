# Mainnet pack: names v3, shop, auction

New contracts for mainnet. The testnet contracts are untouched.

- `src/mainnet/ElyNamesMainnet.sol`: the names. 30-day grace, names from 1 character, owner/manager roles, 3% royalty.
- `src/mainnet/ElyControllerMain.sol`: the shop. Same rules as V4 (referrals 5%/5%, one best discount, expiry premium 2 HYPE to 0 over 14 days, register to another wallet, programs) plus a 1-character price tier and a pause switch for new registrations.
- `src/mainnet/ElyAuction.sol`: English auctions for the single-character names. 1 HYPE reserve, 5% minimum raise, no time extension, outbid money is pulled back by the bidder.

## Test
```bash
forge test        # expect 127 passed
```

## Deploy (launch day, once Elysium mainnet is live)
Add the mainnet RPC to foundry.toml first. OWNER is the deployer wallet; FINAL_OWNER (optional) is the multisig that will take over.
```bash
export OWNER=0xYourDeployer  TREASURY=0xYourTreasury  FINAL_OWNER=0xYourMultisig
forge script script/mainnet/DeployMainnet.s.sol --rpc-url elysium_mainnet --account ely-deployer --sender $OWNER --broadcast
```
This deploys the three contracts, wires them together, and reserves the brand names plus all 36 single characters (a-z, 0-9).
If FINAL_OWNER is set, ownership is OFFERED to it and the multisig must call `acceptOwnership()` on each of the three contracts.

## Schedule the 36 auctions (4 hours each, 40 minutes between = exactly 7 days)
```bash
export AUCTION=0xAuctionAddress  FIRST_START=<unix time of the first auction, in the future>
forge script script/mainnet/ScheduleAuctions.s.sol --rpc-url elysium_mainnet --account ely-deployer --sender $OWNER --broadcast
```
Run this BEFORE handing ownership to the multisig, or have the multisig run it.

## After an auction
Anyone can call `settle(label)` once time is up, then `sendProceeds()` to push the money to the treasury. Outbid bidders call `withdraw()`.

## Admin quick reference
- Shop: `setPrices(single, short, mid, long)`, `setPartner`, `createProgram`, `setReserved`, `setPremium`, `setReferral`, `setPaused`, `withdraw`
- Auction: `schedule`, `cancel`, `setSettings(reserve, minRaiseBps, termDuration, treasury)`
- Names: `setController`, `setRoyalty`

Releasing a single character for normal sale later: `shop.setReserved(["a"], false)`.
