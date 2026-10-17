# .ely Name Service (Elysium), v2

Two contracts:
- `ElyNames`: each name is an ERC-721 NFT with an expiry, on-chain metadata (name, image, expiry date), a 3% ERC-2981 resale royalty, records, and a primary name per wallet.
- `ElyController`: prices (HYPE), commit-reveal, free Kaola claim, partner discounts, reserved names, withdraw.

## Test
```bash
forge test          # should show 43 passed
```

## Deploy to Elysium testnet (chain 99801)
OWNER must be the same wallet that runs the script (it authorizes the controller and sets the reserved list for you).
```bash
export OWNER=0xYourDeployerWallet
export TREASURY=0xWalletThatReceivesSalesAndRoyalties
forge script script/Deploy.s.sol --rpc-url elysium_testnet --account ely-deployer --sender $OWNER --broadcast
```
If gas estimation fails, add `--skip-simulation --gas-estimate-multiplier 200`.

## Admin cheat sheet (from the OWNER wallet, no redeploy)
Controller:
- Prices (wei per year): `setPrices(short, mid, long)`
- Partners: `setPartner(token, discountBps, minBalance)` (5000 = 50% off first year; 0 switches off)
- Free claim: `setFreeClaimOpen(bool)`, `setFreeMinLength(n)`
- Reserved names: `setReserved(["name1","name2"], true/false)`; hand one to its rightful owner with `registerReserved(label, to, duration)`
- Money: `setTreasury(addr)`, `withdraw()`
Names contract:
- Royalty: `setRoyalty(receiver, bps)` (300 = 3%, hard cap 10%)
