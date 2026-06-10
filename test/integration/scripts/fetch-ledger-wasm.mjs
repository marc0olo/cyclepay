#!/usr/bin/env node
/// Fetch the real ic-icrc1-ledger wasm (the suite's ck-USDC stand-in, §6.2)
/// from a pinned dfinity/ic ledger-suite release and verify its sha256 —
/// the same hash-pinned posture as spec §8. The binary is NOT committed;
/// this script is, so what the suite runs against is verifiable.
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

const RELEASE = 'ledger-suite-icrc-2026-03-09';
const SHA256 = '354dd6ecfdc72b5409805b31dea22c9db11df6e14095a5a68924eb63535e6d8a';
const URL = `https://github.com/dfinity/ic/releases/download/${RELEASE}/ic-icrc1-ledger.wasm.gz`;
const DEST = resolve(import.meta.dirname, '..', 'wasm', 'ic-icrc1-ledger.wasm.gz');

const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

if (existsSync(DEST) && digest(await readFile(DEST)) === SHA256) {
  console.log(`ck-USDC ledger wasm present and verified (${RELEASE})`);
  process.exit(0);
}

console.log(`fetching ${URL}`);
const response = await fetch(URL);
if (!response.ok) {
  throw new Error(`download failed: HTTP ${response.status} ${response.statusText}`);
}
const bytes = new Uint8Array(await response.arrayBuffer());
const got = digest(bytes);
if (got !== SHA256) {
  throw new Error(`sha256 mismatch: expected ${SHA256}, got ${got} — refusing to write`);
}
await mkdir(dirname(DEST), { recursive: true });
await writeFile(DEST, bytes);
console.log(`pinned ic-icrc1-ledger.wasm.gz fetched and verified (${SHA256})`);
