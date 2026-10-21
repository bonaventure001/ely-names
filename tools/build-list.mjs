// Build a Merkle list for a partner program.
// Usage: node build-list.mjs input.csv output.json
// input.csv: one entry per line, either "0xWallet" (wallet lists, e.g. DEX volume)
//            or "0xWallet,tokenId" (NFT snapshots). Lines starting with # are ignored.
import fs from "node:fs";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { getAddress } from "ethers";

const [, , inFile, outFile] = process.argv;
if (!inFile || !outFile) {
  console.error("Usage: node build-list.mjs input.csv output.json");
  process.exit(1);
}

const seen = new Set();
const values = [];
for (const raw of fs.readFileSync(inFile, "utf8").split(/\r?\n/)) {
  const line = raw.trim();
  if (!line || line.startsWith("#") || line.toLowerCase().startsWith("wallet")) continue;
  const [addr, id = "0"] = line.split(",").map((x) => x.trim());
  const wallet = getAddress(addr); // throws on a bad address
  if (!/^\d+$/.test(id)) throw new Error(`Bad token id on line: ${line}`);
  const key = `${wallet}:${id}`;
  if (seen.has(key)) continue; // ignore duplicates
  seen.add(key);
  values.push([wallet, id]);
}
if (values.length === 0) throw new Error("No entries found");

const tree = StandardMerkleTree.of(values, ["address", "uint256"]);
const entries = [];
for (const [i, v] of tree.entries()) {
  entries.push({ address: v[0], entryId: v[1], proof: tree.getProof(i) });
}
fs.writeFileSync(outFile, JSON.stringify({ root: tree.root, count: entries.length, entries }, null, 2));
console.log(`Entries: ${entries.length}\nRoot:    ${tree.root}\nSaved:   ${outFile}`);
