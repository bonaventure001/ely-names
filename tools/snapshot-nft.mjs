// Snapshot the holders of an ERC-721 collection at a given block, from its Transfer history.
// Usage:
//   node snapshot-nft.mjs --rpc https://testnet-rpc.elysium.kinetiq.xyz --contract 0xCollection \
//        --block 12345678 --from-block 10000000 --out holders.csv [--exclude 0xEscrow1,0xEscrow2]
// Output: holders.csv with lines "wallet,tokenId", ready for build-list.mjs.
// --from-block should be at or before the block the collection was created.
import fs from "node:fs";
import { JsonRpcProvider, Interface, getAddress, ZeroAddress } from "ethers";

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, cur, i, arr) => (cur.startsWith("--") ? [...acc, [cur.slice(2), arr[i + 1]]] : acc), [])
);
for (const k of ["rpc", "contract", "block", "from-block", "out"]) {
  if (!args[k]) {
    console.error(`Missing --${k}\nSee the comment at the top of this file for usage.`);
    process.exit(1);
  }
}

const provider = new JsonRpcProvider(args.rpc);
const contract = getAddress(args.contract);
const toBlock = Number(args.block);
const fromBlock = Number(args["from-block"]);
const exclude = new Set((args.exclude || "").split(",").filter(Boolean).map((a) => getAddress(a)));
const iface = new Interface(["event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)"]);
const topic = iface.getEvent("Transfer").topicHash;

async function logsInRange(from, to, size) {
  try {
    return await provider.getLogs({ address: contract, topics: [topic], fromBlock: from, toBlock: to });
  } catch (e) {
    if (size <= 500) throw e;
    const mid = Math.floor((from + to) / 2); // range too large for this RPC: split it
    return [...(await logsInRange(from, mid, size / 2)), ...(await logsInRange(mid + 1, to, size / 2))];
  }
}

const logs = [];
const step = 50_000;
for (let from = fromBlock; from <= toBlock; from += step) {
  const to = Math.min(from + step - 1, toBlock);
  logs.push(...(await logsInRange(from, to, step)));
  process.stdout.write(`\rScanned to block ${to} of ${toBlock}`);
}
console.log();

logs.sort((a, b) => a.blockNumber - b.blockNumber || a.index - b.index);
const owner = new Map();
for (const log of logs) {
  const ev = iface.parseLog(log);
  owner.set(ev.args.tokenId.toString(), getAddress(ev.args.to));
}

const rows = [];
const contractHolders = new Set();
for (const [tokenId, wallet] of owner) {
  if (wallet === ZeroAddress || exclude.has(wallet)) continue;
  rows.push([wallet, tokenId]);
}
for (const w of new Set(rows.map((r) => r[0]))) {
  if ((await provider.getCode(w)) !== "0x") contractHolders.add(w);
}
rows.sort((a, b) => (a[0] === b[0] ? Number(a[1]) - Number(b[1]) : a[0].localeCompare(b[0])));
fs.writeFileSync(args.out, rows.map((r) => r.join(",")).join("\n") + "\n");

console.log(`Tokens held: ${rows.length}   Unique wallets: ${new Set(rows.map((r) => r[0])).size}   Saved: ${args.out}`);
if (contractHolders.size) {
  console.log("\nREVIEW: these holders are smart contracts (marketplace escrow, vaults, bridges). Their owners may not be able to");
  console.log("claim from that address. Decide whether to exclude them (--exclude) or handle them separately:");
  for (const c of contractHolders) console.log("  " + c);
}
