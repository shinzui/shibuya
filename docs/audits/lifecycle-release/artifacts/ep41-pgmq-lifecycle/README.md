# EP-41 PGMQ lifecycle evidence

This directory retains EP-41's baseline reproduction, candidate test transcript, focused
paired performance samples, validation summary, and exact implementation identities. The
acceptance decisions are in
`docs/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults.md`.

## Identity

- Reviewed adapter baseline: `392f7545af32ef893c24139fd194d16ec1172f75`
- Adapter implementation: `130b2502a9eaaa2d6f7f927baf9235510297a9f8`
- Adapter contract/ADR: `611bcd8f4ebbeaf1e03a1efacb800b38ce1bafff`
- Final adapter evidence candidate: `fe26ce9064999f6b4e373a6a283139c6f68a5971`
- Exact candidate Shibuya checkout: `4f11f02b763b1679b41af17647e8bd2717b1f4e3`
- Compiler and optimization: GHC 9.12.4, `-O1`
- PostgreSQL: 17.11, started per test by `ephemeral-pg`
- Normalized package/version solution SHA-256:
  `b97f01f6dedb8194392a30ca58650e06ba3332ec40282ce64a546c449add25f6`
- Candidate Cabal test-plan SHA-256:
  `b2a09d025249c546260671d0fbdbf22541f8027a62a72dab0dbad636bde7c26e`
- Baseline Cabal test-plan SHA-256:
  `7600f753f4e1121f15b2ded7d09c1f2bda75fbf61670bd6c2e82b36d57d393c1`
- Machine: MacBookPro18,2, macOS 26.6.1 (25G76), arm64, 10 logical CPUs

The raw Cabal plan hashes differ because the baseline used a detached worktree. Hashing the
sorted package/version pairs produces the identical normalized solution above. Both builds
used the exact candidate `shibuya-core` through ignored `cabal.project.local` files; the
candidate repository-wide build also selected the exact candidate `shibuya-metrics`. No
dependency-bound relaxation or local project file was committed.

## Red/green correctness

An isolated worktree at the reviewed baseline applied a test-only patch with SHA-256
`9d0309be799ff8286a7046d0748ca48af4443ea76d8b7d83cfc5ed0847ecb042`.
The patch makes the existing suite compatible with candidate core and adds only the discarded
commit-confirmation regression. The unchanged production implementation created two DLQ rows
after the same durable delivery was finalized through a fresh handle; the test expected one.
The exact failure, seed `12880255`, and source identity are in `baseline-red.log`.

The final candidate passes 177 examples against real ephemeral PostgreSQL. Its focused cases
prove that a fresh-handle retry after a discarded confirmation and concurrent callers converge
on one DLQ row; failed DLQ sends roll back the source claim; exhausted and automatic failures
remain visible; cancellation releases per-handle ownership; renewal outages retry; database
restart preserves the delivery for lease-expiry redelivery; prefetch shutdown loses no message;
and repeated graceful stop returns the completed result. The transcript summary is in
`candidate-full.log`.

The durable fix is the source-row claim itself, not the in-memory lock. The transaction deletes
the source first, sends only when the Boolean delete result is true, and relies on PostgreSQL
rollback to restore the row if the send fails. This keeps the contract at-least-once and does
not claim exactly-once handler side effects.

## Focused performance

The reviewed baseline and candidate alternated ten measured runs of the unchanged live test
`AckOk is idempotent after a successful finalize`, reversing pair order on even pairs. Every run
created an isolated ephemeral database and passed. The raw samples are in
`focused-performance.csv`; a deterministic 100,000-resample paired bootstrap with seed 410041
is summarized in `focused-performance-summary.json`.

- Baseline mean: 4.243106 seconds
- Candidate mean: 4.326039 seconds
- Mean paired latency change: +2.009%
- 95% confidence interval: +0.039% to +4.214%

The adverse confidence bound is below EP-45's 10% focused latency budget. This narrow
service-inclusive check does not replace EP-45's final candidate throughput, tail-latency,
allocation, memory, and soak matrix.

## Other validation

The candidate adapter, example, and endurance executable build together against the exact
candidate core/metrics packages. Haddock generation exits zero and documents the new public
exception; it retains existing link and coverage warnings. `nix fmt`, `nix flake check`, Mori
configuration validation, capability graph generation, and strict capability profile/log
validation all pass. The strict pass required adding review provenance to all six capability
records after reviewing their current content. Details are in `validation.log`.
