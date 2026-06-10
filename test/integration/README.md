# PocketIC integration suite — the Card-rail go-live bar (spec §9)

End-to-end scenarios against a PocketIC instance running the **real** NNS
canisters: the ICP ledger, the cycles minting canister, and the cycles ledger
are deployed at their mainnet IDs by PocketIC's `icpFeatures` (the same Wasms
mainnet runs, kept in sync with the instance topology by the server). The
suite plays every external role itself:

- **Stripe** — crafted `checkout.session.completed` / `charge.refunded`
  payloads, HMAC-SHA256-signed exactly per the `Stripe-Signature` scheme,
  delivered through the canister's real HTTP ingress path.
- **The forex source** — `create_order`'s HTTPS outcall is intercepted with
  PocketIC's pending-outcall API and answered with mock bodies (success,
  malformed, and outage cases); the canister's own `forex_transform` runs
  for real.
- **NNS governance** — the CMC's ICP/XDR conversion rate is set by calling
  `set_icp_xdr_conversion_rate` with the governance canister principal as
  sender (PocketIC permits arbitrary senders).
- **Time** — staleness windows, the recovery timer, and the treasury
  max-wait are driven with PocketIC time control; mid-flight interruption
  tests step rounds one tick at a time and upgrade the canister inside the
  §5.1 ambiguity windows.

## Running

```sh
cd test/integration
npm ci
npm test        # pretest builds the backend wasm via `mops build`
```

Requirements: Node ≥ 20.11 and `mops` on PATH. The PocketIC server binary
ships with the `@dfinity/pic` npm package.

**The host must run a 4 KiB-page kernel** — macOS (Intel or Apple Silicon)
and x86_64 Linux are fine. The IC replica's memory tracker hard-asserts
4096-byte pages, so the suite cannot run inside arm64 Linux VMs with 16 KiB
kernels (notably Apple-Silicon Docker/sandbox guests); the server crashes at
instance creation. Run it on the host or in CI instead.

## CI

`ci/integration.yml` is a ready GitHub Actions job (ubuntu-latest is
x86_64, so PocketIC runs natively). It lives here rather than in
`.github/workflows/` only because the sandbox's deploy token lacks the
`workflow` scope; to enable it:

```sh
git mv test/integration/ci/integration.yml .github/workflows/integration.yml
git commit && git push   # needs a workflow-scoped token (a normal `gh auth` token is fine)
```

## Scenario map (spec §9 coverage)

| # | Scenario | §9 item |
|---|----------|---------|
| 01 | 503 before secret provisioning, controller-gated admin API | — |
| 02 | tier config gating | — |
| 03 | empty cache + failing refresh → `#rateUnavailable` (3-attempt cap) | forex fail-closed |
| 04 | mocked outcall through the real transform; §3 pricing vector; order authz | happy path (pricing half) |
| 05 | signature/window/404/405/413 guards on the live route table | duplicate/replay (guards) |
| 06 | default burn cap 0 holds the mint | AwaitingTreasury |
| 07 | cap sized → resume → real ledger transfer → CMC mint → forward | happy path |
| 08 | event-id dedup, intent dedup, Type 1 `#duplicate`, refund auto-resolve | duplicate/replay, Type 1 |
| 09 | claimed-not-trusted attribution → Type 1 `#unattributed` | Type 1 |
| 10 | delivery to a real cycles-ledger account | happy path (2nd forward arm) |
| 11 | forward to a nonexistent canister → Type 2, cycles refunded to app balance | Type 2 |
| 12 | upgrade mid-transfer → §5.1 intent replay, exactly-one ledger debit, timer re-arm | upgrade-mid-flight, ambiguous-transfer recovery, postupgrade re-arm |
| 13 | upgrade mid-forward → `#ambiguousForward` escalation, never re-forwards | ambiguous-transfer recovery |
| 14 | treasury max-wait → `treasuryWaitExceeded` escalation | AwaitingTreasury |
| 15 | audit-log seq monotonicity + error-queue accounting | — |
