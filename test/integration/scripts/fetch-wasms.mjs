#!/usr/bin/env node
/// Fetch the external canister Wasms the suite runs against, each pinned by
/// sha256 — the same hash-pinned posture as spec §8. The binaries are NOT
/// committed; this script is, so what the suite tested against is verifiable
/// from the repo alone.
///
/// - **xrc_mock** — DFINITY's own Exchange Rate Canister mock, installed at the
///   mainnet XRC id. Its response is fixed by the init argument, so the suite
///   reinstalls it to change the rate or to make it return a specific
///   `ExchangeRateError`. Using the official mock rather than a hand-rolled stub
///   means the Candid contract under test is the real one.
import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';

const WASM_DIR = resolve(import.meta.dirname, '..', 'wasm');

const TARGETS = [
  {
    name: 'xrc_mock.wasm.gz',
    label: 'XRC mock',
    url: 'https://github.com/dfinity/exchange-rate-canister/releases/download/2026.07.10/xrc_mock.wasm.gz',
    sha256: '037d1137e587fd4086311242d5b8ec9cae50eeba29e98cbcb661ae11e9658d11',
  },
];

const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');

for (const target of TARGETS) {
  const dest = resolve(WASM_DIR, target.name);
  if (existsSync(dest) && digest(await readFile(dest)) === target.sha256) {
    console.log(`${target.label} present and verified`);
    continue;
  }
  console.log(`fetching ${target.url}`);
  const response = await fetch(target.url);
  if (!response.ok) {
    throw new Error(`${target.label} download failed: HTTP ${response.status} ${response.statusText}`);
  }
  const bytes = new Uint8Array(await response.arrayBuffer());
  const got = digest(bytes);
  if (got !== target.sha256) {
    throw new Error(
      `${target.label} sha256 mismatch: expected ${target.sha256}, got ${got} — refusing to write`,
    );
  }
  await mkdir(dirname(dest), { recursive: true });
  await writeFile(dest, bytes);
  console.log(`${target.label} fetched and verified (${target.sha256})`);
}
