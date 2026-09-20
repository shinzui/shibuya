# EP-40 Kafka lifecycle evidence

This directory retains EP-40's baseline reproductions, candidate test transcripts, focused
paired performance samples, and implementation identities. The acceptance decisions are in
`docs/plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries.md`.

## Identity

- Reviewed adapter baseline: `6c0cd3fc840c9f5ba48558ca94c7d826a3da6c9f`
- Adapter implementation: `554c969b1d95842628d0483f7ae6331c87249a84`
- Adapter documentation/ADR candidate: `796dc07238a053c5f114993fc9763e72f04d7b51`
- Exact candidate Shibuya checkout: `96992dfb3d11a55f50c5443bc7321d3a90e61a47`
- Compiler and optimization: GHC 9.12.4, `-O1`
- Normalized package/version solution SHA-256: `fe5c23ea23174cfbb75b78f28a5c1494cad13347feb464f3908b0e372d5204e5`
- Candidate Cabal plan SHA-256: `34ec56c45eee6dbc56d1bd0db8d055cdb111a0538214aadaab0ce802364a47ff`
- Baseline Cabal plan SHA-256: `f5976d2e2dcf66c61a448d4d2bacbe6e5bc164cf2e9d0c29b5f43dcaf322640b`
- Machine: MacBookPro18,2, macOS 26.6.1 (25G76), arm64, 10 logical CPUs
- Broker: Redpanda 26.2.1 at the local test endpoint; `rpk` 26.2.3

The two raw Cabal plan hashes differ because local package source paths include the detached
worktree location. Hashing the sorted package/version pairs produces the identical normalized
solution hash above. Both builds used the exact candidate `shibuya-core` checkout through an
ignored `cabal.project.local`; no dependency-bound relaxation was committed.

## Red/green correctness

An isolated worktree at the reviewed baseline applied a test-only patch with SHA-256
`a084fd2f18cffe5c34b604353d214178171e78414e96fbd8df4081ace5149d00`. The focused
AckHandle run failed both new regressions:

- retries for offsets 42 then 43 sought `[42, 43]` instead of preserving `[42, 42]`;
- an exhausted acknowledgement returned normally instead of throwing at the finalizer.

The exact transcript is in `baseline-red.log`. The candidate's 16-case AckHandle group passes
the earliest-unresolved reference model for seeds 400040 through 400049, duplicate and replay
identity, bounded seek timeout, cancellation lock release, revoke fencing, direct terminal
failure, and source diagnostics. The full suite passes 53 tests, including live-broker buffered
retry/restart, synthetic revocation, actual two-consumer reassignment, and repeated shutdown.
The relevant command summaries are in `candidate-ackhandle.log` and `candidate-full.log`.

The live reassignment test installs the real librdkafka callback on two consumers in one group,
waits for an actual revoke, invokes a retained callback from the old owner, then restarts the
group and observes the revoked partition's payload again. This proves broker-visible recovery,
not merely a mock call count. The adapter deliberately has no DLQ producer, so "DLQ producer
failure" is not an executable path; `AckDeadLetter` remains an explicitly documented warning
plus offset store.

## Focused performance

The pre-remediation and candidate binaries alternated ten measured runs of the unchanged live
test `AckRetry redelivers within the same session`. Every run created an isolated topic and
passed. The raw samples are in `focused-performance.csv`; a deterministic 100,000-resample
paired bootstrap with seed 400040 is summarized in `focused-performance-summary.json`.

- Baseline mean: 3.524629 seconds
- Candidate mean: 3.528930 seconds
- Mean paired latency change: +0.123%
- 95% confidence interval: -0.117% to +0.334%

The adverse confidence bound is below EP-45's 10% focused latency budget. This narrow
service-inclusive check does not replace EP-45's final N1/N4 throughput, tail-latency,
allocation, memory, and soak matrix.

## Other validation

`nix fmt` completed with no remaining change. The strict capability profile/log validation
reported `OK: 4 concepts (okf_version 0.2)`. `nix flake check` reached the pre-existing default
package output and failed because the generated `callCabal2nix` points at the repository root,
which contains no Cabal file. The failure is reproduced in `validation.log`; it is unrelated to
the EP-40 source change and remains an explicit EP-44 build/candidate obligation rather than a
claimed pass.
