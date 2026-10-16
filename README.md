# .ely Name Service (Elysium)

Two contracts:
- `ElyNames`: the registry. Each name is an NFT with an expiry; also stores address/text records and each wallet's primary name.
- `ElyController`: the shop. Prices (HYPE), commit-reveal, free Kaola claim, partner discounts, withdraw.

## 1. Setup (WSL Ubuntu)
```bash
cd ely-names
git init
forge install foundry-rs/forge-std OpenZeppelin/openzeppelin-contracts@v5.1.0
forge test          # should show 35 passed
```

## 2. Check Kaola is a standard ERC-721 (must print `true`)
```bash
cast call 0xE99D7A5CB301f023849888D5F34a43bB7f39D841 "supportsInterface(bytes4)(bool)" 0x80ac58cd --rpc-url https://testnet-rpc.elysium.kinetiq.xyz
```

## 3. Deploy to Elysium testnet (chain 99801)
Never paste your private key anywhere. Store it in an encrypted keystore (it asks you to type it, hidden):
```bash
cast wallet import deployer --interactive
export OWNER=0xYourAdminWallet
export TREASURY=0xYourFundsWallet
forge script script/Deploy.s.sol --rpc-url elysium_testnet --account deployer --broadcast
```
Get testnet HYPE from the faucet on the Elysium site first. If the deploy fails on gas estimation, add `--skip-simulation --gas-estimate-multiplier 200`.

Then, from the OWNER wallet, authorize the controller (one time):
```bash
cast send <ElyNames address> "setController(address,bool)" <ElyController address> true --rpc-url elysium_testnet --account deployer
```

## Admin cheat sheet (all from the OWNER wallet, no redeploy)
- Change prices (wei per year): `setPrices(short, mid, long)`
- Add/update a partner: `setPartner(tokenAddress, discountBps, minBalance)`; 5000 = 50% off the first year; use `1` for NFTs, a bigger number for DeFi tokens; `0` bps switches a partner off
- Free claim: `setFreeClaimOpen(bool)`, `setFreeMinLength(n)`
- Money: `setTreasury(addr)`, `withdraw()`
