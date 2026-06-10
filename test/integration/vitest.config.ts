import { defineConfig } from 'vitest/config';

// One PocketIC instance per spec file, scenarios run sequentially within it —
// instance creation (NNS + ledger + CMC + cycles ledger) is the expensive
// part, and several scenarios deliberately build on prior on-chain state.
export default defineConfig({
  test: {
    include: ['src/**/*.spec.ts'],
    fileParallelism: false,
    testTimeout: 300_000,
    hookTimeout: 300_000,
    teardownTimeout: 60_000,
  },
});
