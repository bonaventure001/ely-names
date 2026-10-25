# Controller V4: referrals, expiry premium, register to another wallet

ElyNames is NOT changed. V4 is a new shop next to the old ones. Every name, record and expiry stays.

## Install and test
```bash
cd ~/ely-names
unzip -o /mnt/c/Users/bonav/Downloads/ely-contracts-v4.zip
forge test                                   # expect 92 passed
```

## Deploy to testnet
OWNER must be the wallet that runs the script and owns ElyNames. LEGACY is the FIRST controller (so Kaola ids that already claimed stay claimed).
```bash
export OWNER=0xF7129Da0385df3Fa7AdE02E417541e140c298D3C
export TREASURY=0xF7129Da0385df3Fa7AdE02E417541e140c298D3C
export NAMES=0x13A130B336400409c956dF042C128238F1486ddD
export LEGACY=0x1dA6a196405dCc455195eb00B4F7D17106164e0A
forge script script/DeployV4.s.sol --rpc-url elysium_testnet --account ely-deployer --sender $OWNER --broadcast
```

## The rules, as built
- One discount only: the best of (partner holding discount, program discount, referral discount). They never add up. The discount covers the first year only.
- Referral: the new user gets 5% off. The referrer earns 5% of the price the new user paid (after the discount, before any premium). The referrer must hold an ACTIVE PRIMARY NAME; a self-referral, or one where the referrer is the receiving wallet, is ignored. An ignored referral changes nothing: no discount, no reward.
- Referral money is held in the contract and is walled off: `withdraw()` can never touch it. Referrers take theirs with `claimReferral()`.
- Premium: when a name expires and its grace period (read from ElyNames) ends, it opens to everyone at its normal price plus a premium that starts at 2 HYPE and falls in a straight line to 0 over 14 days. The premium is never discounted and never earns a referral reward.
- During the grace period only the owner side can act: anyone can pay to renew it at the normal price, nobody else can register it.
- Register to another wallet: the `owner` field of the registration is the wallet that receives the name; the payer can be a different wallet.

## Admin cheat sheet (OWNER wallet, no redeploy)
- Premium: `setPremium(start, period)` (start up to 100 HYPE, period up to 90 days)
- Referral: `setReferral(rewardBps, discountBps)` (each capped at 2500 = 25%; 500 = 5%)
- Prices, partners, programs, reserved names, treasury, `withdraw()`: same as V3.

## Switching over (after testing)
1. `cast send $V3 "withdraw()" ...` (old shop earnings)
2. `cast send $NAMES "setController(address,bool)" $V3 false ...`
3. Names keep working and renew through V4.
Note: programs are not copied from V3. Create them again on V4 (the Kaola snapshot program, partner programs).
