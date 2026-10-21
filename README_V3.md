# Controller V3: partner programs (snapshot lists)

ElyNames is NOT changed. Deploying V3 adds a new shop next to the old one. Names, records, expiries and primary names stay.

## One-time setup
```bash
cd ~/ely-names
forge test                                  # expect 63 passed
cd tools && npm install && cd ..            # installs the list tools
export OWNER=0xF7129Da0385df3Fa7AdE02E417541e140c298D3C
export TREASURY=0xF7129Da0385df3Fa7AdE02E417541e140c298D3C
export NAMES=0x13A130B336400409c956dF042C128238F1486ddD
export LEGACY=0x1dA6a196405dCc455195eb00B4F7D17106164e0A
forge script script/DeployV3.s.sol --rpc-url elysium_testnet --account ely-deployer --sender $OWNER --broadcast
```
Note the printed ElyControllerV3 address. Then the website must point at it (one config line).

## Adding a partner (the same 6 steps every time)
1. Agree the rule and the dates with the partner (for example: 10,000+ USD volume between two dates; 20% off the first year).
2. Take the snapshot.
   - NFT holders: `node tools/snapshot-nft.mjs --rpc https://testnet-rpc.elysium.kinetiq.xyz --contract 0xCOLLECTION --block SNAPSHOT_BLOCK --from-block 0 --out holders.csv`
   - Activity (DEX volume): the partner or you export the qualifying wallets, one per line, into a CSV.
3. Build the list: `node tools/build-list.mjs holders.csv list.json` (prints the root).
4. Host `list.json` publicly (put it in the repo's docs/lists/ folder so it is public) and share the link and the root with the partner so both sides can check it.
5. Create the program (owner wallet). Example for a 20% off program:
```bash
cast send $V3 "createProgram((string,address,bytes32,uint16,uint64,uint64,uint64,uint32,uint8,bool,string))" '("Partner name",0xMANAGER_WALLET,0xROOT,2000,START_UNIX,END_UNIX_OR_0,SNAPSHOT_UNIX,CAP_OR_0,MIN_LENGTH,false,"https://elysiumnameservice.xyz/lists/partner.json")' --rpc-url elysium_testnet --account ely-deployer
```
   Meaning of the fields: name, who may update the list before it starts, root, discount in basis points (2000 = 20%, 10000 = free first year), start time, end time (0 = no end), snapshot time (for transparency), maximum claims (0 = unlimited), shortest allowed name, whether to also block Kaola ids already claimed on the old controller (true only for the Kaola program), list link.
6. Announce the dates. The list is frozen from the start time: nobody, not even you, can change it after that.

Partner can publish the list themselves: `setProgramRoot(programId, root, listURI)` from the MANAGER wallet, before the start time only.

## Switching over (after testing)
- Withdraw anything in the old shop: `cast send $LEGACY "withdraw()" ...`
- Switch the old controller off: `cast send $NAMES "setController(address,bool)" $LEGACY false ...`
- Existing names keep working and renew through V3.

## What each check protects
- The list is a Merkle root: only wallets on the published list can claim, and a proof only works for the wallet it was made for.
- Each list entry is single use. NFT lists are per token id, so a sold NFT cannot claim again.
- Programs have start and end times, an optional total cap, and a pause switch.
- Programs and holding-based discounts do not stack: the better one applies.
