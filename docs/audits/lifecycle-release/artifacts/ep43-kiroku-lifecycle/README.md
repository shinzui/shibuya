# EP-43 Kiroku lifecycle evidence

This directory retains EP-43's baseline reproduction, candidate test summaries, focused
paired performance samples, validation summary, and exact implementation identities. The
acceptance decisions are in
`docs/plans/43-make-kiroku-subscription-ownership-exception-safe.md`.

## Identity

- Reviewed Kiroku baseline: `758b81acddf482b08643acf8802f095e621a3e07`
- Kiroku implementation: `eb67688690d5e96427cb8ff6cbf1488b81c279cf`
- Exact candidate Shibuya checkout: `b2b0332133b4251c92b82787264aafe4b83fef3f`
- Compiler and optimization: GHC 9.12.4, `-O1`
- PostgreSQL: 17.11, started per test by `ephemeral-pg`
- Normalized package/version solution SHA-256:
  `c3cdda5e9008c9e3afe43dd2d26cee8d88557daa2a8ade18fb66dd44e642b54c`
- Candidate Cabal test-plan SHA-256:
  `076c43e73c62df9d34852bb3827a355bfe52a9548f7d42f37e85a948aba130f0`
- Baseline Cabal test-plan SHA-256:
  `a14552d6a238dad7ee7a01e79fad05a2c4e59adebb573d2065f1f2c2c8479c4e`
- Machine: MacBookPro18,2, macOS 26.6.1 (25G76), arm64, 10 logical CPUs

The raw Cabal plan hashes differ because the baseline used a detached worktree. Hashing the
sorted package/version pairs produces the identical normalized solution above. Both builds
used a temporary Cabal project selecting the exact candidate `shibuya-core`; no dependency
bound relaxation or local project file was committed. An ignored user `cabal.project.local`
adds `codd-extras` with an incompatible historical `ephemeral-pg` bound, so it was preserved
but excluded from these exact-project runs.

## Red/green correctness

An isolated worktree at the reviewed baseline applied a test-only patch with SHA-256
`b3e9cdcf024171e6156846472b7052b688e252f46c78e985ccfb2fe2152d443b`.
The patch makes an existing group-construction regression throw from member 1 cleanup after
member 2 acquisition fails. The unchanged implementation replaced the primary member 2 error
with the cleanup error and stopped before cleaning member 0. The exact failure and seed
`571275122` are in `baseline-red.log`.

The candidate adapter passes 38 examples against real ephemeral PostgreSQL. Its deterministic
fault tests prove that group acquisition owns each returned member before cancellation can
arrive, all acquired members are shut down in LIFO order even when one cleanup throws, and the
primary acquisition failure is retained. The ownership helper is a private Cabal sublibrary;
the fault hook is unavailable from the public adapter API.

The candidate also proves duplicate acknowledgement finalization, retry, handler-exception,
dead-letter, source-error, AckHalt, and coordinated-shutdown behavior. A test-only Kiroku
checkpoint hook interrupts the worker after an AckOk reply but before the database save: the
checkpoint remains at zero, restart replays the event, and the subscription registry is empty.
Existing checkpoints win even with `FromCurrentHead`; `FailIfMissing` produces its typed error
without a registry leak. The whole `kiroku-store` suite passes 308 examples, including bridge
cancellation that is repeatable and leaves no subscription thread registered. Summaries are in
`candidate-full.log`.

The change preserves the accepted at-least-once contract in
`mori://shinzui/kiroku/okf/adrs/concepts/ADR-4`: cancellation may replay unresolved work,
ordinary checkpoint saves remain monotonic, and no exactly-once external side effects are
claimed. Adapter documentation now states that synchronous handler exceptions become an
immediate `AckRetry` under candidate core while asynchronous cancellation is not converted.

## Focused performance

The reviewed baseline and candidate alternated ten measured runs of the unchanged live test
`kirokuAdapter / shuts down all subscriptions coordinately`, reversing pair order on even
pairs. Every run created an isolated ephemeral database and passed. The raw samples are in
`focused-performance.csv`; a deterministic 100,000-resample paired bootstrap with seed 430043
is summarized in `focused-performance-summary.json`.

- Baseline mean: 0.34995 seconds
- Candidate mean: 0.35034 seconds
- Mean paired latency change: -0.0803%
- 95% confidence interval: -3.373% to +4.294%

The adverse confidence bound is below EP-45's 10% focused latency budget. This narrow
service-inclusive shutdown check does not replace EP-45's final candidate throughput,
tail-latency, allocation, memory, and soak matrix.

## Other validation

The adapter package passes `cabal check`; the owning Kiroku repository passes `nix fmt`,
`nix flake check`, capability validation, and its capability graph checks. The Shibuya evidence
validator accepts the closed findings and all five Kiroku persistence cells. Details are in
`validation.log`.
