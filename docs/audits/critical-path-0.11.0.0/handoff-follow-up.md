# Intake handoff follow-up, 2026-10-25

The retained change removes the per-message nested STM transaction in
`inboxToStream`. All correctness suites pass. The full release comparison passes
61 of 62 benchmarks: the previously regressing 1,000-message processing case is
now 12% faster than release, while `counter-100` still fails at +22.9%.
This is a partial performance repair, not a passing release gate.

## Retained implementation

Check queue emptiness and receive within one STM transaction. On a nonempty
queue, receive exactly one message. Only an empty queue reads the shared
source-completion/terminal wake cell and retries when it is not set. The queue
state and wake decision remain atomic. No prefetch buffer or additional
admission is introduced; inbox capacity, source ownership, handler ownership,
ordering, cancellation, metrics and tracing behavior remain unchanged.

Previously every receive used `orElse`, including successful receives from a
populated queue. GHC 9.12.4 starts a nested transaction for that branch. Removing
it reduces work in the drain loop. The selected NQE implementation delegates its
bounded inbox operations to STM's `TBQueue`; its emptiness check reads the same
queue-list TVars that receiving already needs. The new check does not add the
completion TVar to the populated queue's read set.

Mori lookup located `mori://haskell/stm/packages/stm` and
`mori://simonmar/async/packages/async`. NQE and UnliftIO were absent from the local
registry search; their exact selected sources were inspected from Hackage:
`mori://xenog/nqe/packages/nqe` version 0.6.6 and
`mori://fpco/unliftio/packages/unliftio` version 0.2.25.1. No dependency version,
bound or compiler setting changed. The nested-transaction implementation was
verified in `mori://ghc/ghc`, project-relative `rts/PrimOps.cmm` at
`ghc-9.12.4-release` (artifact-level source URI pending).

## Candidate selection

Each experiment used the same eight existing cases, matched release binary,
package-default RTS and unchanged 10% gate, with `--stdev 3 --timeout 120`.
Every comparison, including failures, is retained in the measurement artifact.
The following are paired results from each experiment, not comparisons against
one reused favorable baseline.

| Candidate | counter-100 release/current µs | Change | Focused gate | Decision |
| --- | ---: | ---: | ---: | --- |
| Single-transaction receive | 37.87 / 46.82 | +23.6% | 7/8 pass | Retain the smaller processing improvement; counter remains open |
| Plus serial-ingester placement | 42.38 / 53.53 | +26.3% | 7/8 pass | Reject; placement did not recover the short counter |
| Plus per-invocation provider rollback | 42.37 / 48.00 | +13.3% | 6/8 pass | Reject; runWithMetrics-100 also regressed |
| Plus concrete-queue specialization | 38.08 / 55.85 | +46.6% | 7/8 pass | Reject; larger code change still fails the counter |
| Plus unpaused IO source fold | 37.88 / 54.56 | +44.0% | 7/8 pass | Reject; it did not recover the counter |

The rejected changes were restored before final validation. The final source
matches the original single-transaction candidate patch exactly. Shared no-op
providers and ordinary thread migration remain in place. No generic queue API,
ingester affinity or source-fold rewrite is retained.

## Final validation

All 287 core examples, 104 metrics examples, and both isolated GC suites pass.
Existing tests cover finite drain, idle-intake halt wakeups across Serial,
Ahead, Async, partitioned and batch processing, terminal failure, source
cancellation, pause and trace ownership. Formatting and diff checks pass.

The complete existing benchmark workflow ran release and candidate sequentially
with `--stdev 5 --timeout 120 --fail-if-slower 10` on the candidate. Both contain
62 matching cases. The release capture completed in 112.63 seconds; the candidate
in 110.68 seconds. Exactly one candidate case failed: `counter-100`.

| Case | Release µs | Candidate µs | Change |
| --- | ---: | ---: | ---: |
| counter-100 | 41.92 | 51.51 | +22.9% |
| counter-1000 | 421.06 | 410.34 | −2.5% |
| counter-10000 | 4465.71 | 4248.89 | −4.9% |
| runWithMetrics-100 | 45.67 | 46.35 | +1.5% |
| runWithMetrics-1000 | 340.76 | 299.90 | −12.0% |
| runWithMetrics-10000 | 3941.33 | 3530.19 | −10.4% |
| cpu-bound-serial / 1000-msgs | 423.56 | 405.72 | −4.2% |
| cpu-bound-serial / 10000-msgs | 4256.21 | 3530.13 | −17.1% |

Values are CPU microseconds per invocation. The CSV two-standard-deviation
estimates and allocations are preserved; rounding in this table does not affect
the gate. All concurrent and lifecycle cases passed. No build, test or event
parser ran concurrently with the measurements. The host remains a shared
workstation, so this is not an exclusive-host claim.

A final paired comparison against the immutable pre-change binary (same two
existing cases, `--stdev 3 --timeout 120`) measured counter-100 at 50.62 →
46.85 µs (−7.5%) and runWithMetrics-1000 at 357.99 → 285.94 µs (−20.1%).
Both passed the before/after comparison. These pairs support retaining the
smaller improvement; they do not erase the failed release comparison or prove
that the remaining scheduling variability is resolved.

## Remaining counter investigation

The earlier phase and scheduler evidence still applies: migration patterns
strongly affect the short counter, while setup itself is cheap. Reducing queue
work repairs the processing regression but does not reliably restore the short
counter. Pinning just the ingester did not solve it, and provider rollback still
failed other short cases. The exact allocation/layout trigger remains unresolved.

A useful next diagnostic is a standalone reproducer that reduces the fork,
queue and provider setup to the smallest program that retains the regression,
followed by lower-level heap/scheduler instrumentation as needed. This would
change benchmark tooling/workload and requires separate authorization under
`AGENTS.md`. It must remain separate from the original workloads and release
thresholds. No new reproducer or compiler/RTS build has been started.

## Evidence

- [handoff-measurements.json](handoff-measurements.json) retains all five
  experiments, the full comparison and the final before/after control.
- [handoff-metadata.json](handoff-metadata.json) identifies the retained binary,
  source patch, compiler/RTS settings and validation results.

The immutable measured candidate, all rejected candidate patches/binaries,
commands, CSV files and logs are retained under
`/tmp/shibuya-handoff-investigation`. The pre-change binary is the immutable
candidate from `/tmp/shibuya-phase-investigation`. The final tests are recorded
in `tests.log`; full benchmark captures are `full-release.csv` and
`full-candidate.csv` with adjacent logs. The repository measurement artifact
retains the observations and command arguments; metadata identifies binary and
source hashes. No diagnostic changes to the benchmark suite are retained.

The normal benchmark rebuild also passes. Its executable hash differs from the
immutable measured binary despite matching source; the recorded performance
results refer to the immutable binary identified in metadata.
