# Critical-path regression investigation, 2026-10-25

Follow-up: [the single-transaction intake repair](handoff-follow-up.md) passes all
correctness suites and 61/62 full benchmark comparisons. It resolves the observed
processing-1000 regression; the short counter remains open. The evidence below
records the preceding investigation.

The ingestion cancellation bug is fixed in `848eb31`; the performance gate still
fails. This investigation identifies scheduler migration and the concurrent
intake/drain interval as the performance problem. It does not claim a safe
production performance fix or a passing full release gate.

## Correctness repair

[ExecPlan 53](../../plans/53-preserve-ingestion-cancellation-across-telemetry-callbacks.md)
is complete. Ingestion's owner executes source effects, while an owned worker
executes SDK lifecycle callbacks that can swallow asynchronous exceptions. The
source retains its thread, local effect state and context; disabled tracing runs
directly. Four callback regressions fail on the original code and pass after the
repair. All 287 core examples, 104 metrics examples, and both isolated GC suites
pass. Formatting and diff checks pass.

## Fixed comparison set

Release runtime: `v0.10.0.1` (`de42f07`). Candidate: `848eb31`, including the
cancellation repair. Both use the same current benchmark harness (`016576f`),
GHC 9.12.4, dependency versions **and unit IDs**, and optimization levels
(library `-O1`, benchmark `-O2`). The host is an Apple M5 Ultra with 36 capabilities
under package-default `-N -T -A32m`. Builds, tests and event parsing were stopped
during measurements. This is a shared workstation, not an exclusively reserved
machine; no claim of complete host isolation is made.

Each existing case ran release then candidate, with `--stdev 3 --timeout 120` and
the unchanged `--fail-if-slower 10` comparison. Values below are CPU microseconds
per benchmark invocation, not per message. Raw two-standard-deviation estimates
and allocations are retained in [measurements.json](measurements.json).

| Existing case | Release µs | Candidate µs | Change | Gate |
| --- | ---: | ---: | ---: | --- |
| counter-100 | 42.99 | 50.31 | +17.0% | Fail |
| counter-1000 | 375.20 | 381.15 | +1.6% | Pass |
| counter-10000 | 3846.59 | 4179.20 | +8.6% | Pass |
| runWithMetrics-100 | 49.21 | 44.21 | −10.2% | Pass |
| runWithMetrics-1000 | 319.72 | 364.66 | +14.1% | Fail |
| runWithMetrics-10000 | 3889.39 | 3975.30 | +2.2% | Pass |
| cpu-bound-serial / 1000-msgs | 380.95 | 375.28 | −1.5% | Pass |
| cpu-bound-serial / 10000-msgs | 3763.18 | 3786.46 | +0.6% | Pass |

Both failures were repeated twice with unchanged binaries: candidate then
release, followed by release then candidate. No result was discarded.

| Case | Pair 1 release/current | Pair 2 release/current | Pair 3 release/current |
| --- | ---: | ---: | ---: |
| counter-100 | 42.99 / 50.31 | 42.21 / 55.16 | 42.38 / 58.93 |
| runWithMetrics-1000 | 319.72 / 364.66 | 314.80 / 360.44 | 320.61 / 362.06 |

The counter regression is consistent in direction but varies substantially
between current-binary launches (+17% to +39%). Within-run deviation does not
capture that launch-to-launch variation. The processing regression reproduces
at +13% to +15%. These repeats confirm failures; they do not authorize a threshold
change or substitute a new statistical release policy.

## Phase and scheduler evidence

All measurements in this section are **diagnostic**, not gate results. The
workloads are unchanged. Phase markers identify benchmark setup, runtime setup,
fork, processor setup, drain, join and return, plus the concurrent source lifetime.
Event logs distinguish scheduled thread intervals from time off the capability.
These intervals are elapsed time, not CPU attribution: OS descheduling is included,
and ingestion overlaps processing, so source time must not be added to parent
elapsed time.

The first instrumentation used `traceEventIO`. Its string encoding/allocation
raised ingester migration from roughly 11% to 79% even on release counter-100,
masking the original gap. Those captures are retained and **not** used to claim
an exact attribution of the uninstrumented slowdown. A second capture used
static-address `traceEvent#` markers to avoid string encoding/allocation. The
[diagnostic patch](static-marker-diagnostic.patch) records the candidate edits;
matching markers were applied to release. All diagnostic source edits were
restored. The phase instrumentation is not part of the benchmark workflow.

The lower-overhead counter capture contains 32,767 complete invocations for each
binary, with no missing phase markers or orphan source events:

| Phase, elapsed µs | Release | Candidate |
| --- | ---: | ---: |
| Entry setup | 0.29 | 0.25 |
| Runtime setup | 0.30 | 0.31 |
| Fork | 0.14 | 0.13 |
| Processor setup | 0.18 | 0.31 |
| Concurrent intake/drain interval | 37.88 | 41.21 |
| Final join | 0.14 | 0.14 |
| Return | 0.05 | 0.05 |
| Total | 38.99 | 42.40 |

Almost all of the observed elapsed delta is in concurrent intake/drain. This does
not identify the handler itself as slower. Splitting the same invocations by
migration pattern is more informative:

| Migration pattern | Release share | Candidate share | Release elapsed µs | Candidate elapsed µs |
| --- | ---: | ---: | ---: | ---: |
| Neither thread migrates | 46.6% | 32.3% | 29.43 | 29.74 |
| Processor only | 33.0% | 36.5% | 43.74 | 44.05 |
| Ingester only | 20.4% | 31.2% | 52.80 | 52.90 |

The rare both-migrated cases (1 release, 3 candidate) remain in the raw summary
and overall means. Costs within each common pattern barely change; current code
enters the slower patterns more often. This is an observed association, supported
by the migration-disabled intervention below, not proof of a particular cache-line
conflict or STM instruction being the cause.

Event logs from the **uninstrumented binaries** also reproduce the pattern.
Counter-100 ingester migrations rise from 0.111 to 0.291 per invocation; processor
migrations rise from 0.109 to 0.388 and processor yields from 0.278 to 0.799.
For runWithMetrics-1000, processor migration rises from 0.016 to 0.494; ingester
migration falls from 0.568 to 0.505. Thus looking only at ingester migration would
miss the second regression. Processor scheduled intervals increase from 204.68 to
232.71 µs, and ingester intervals from 88.41 to 98.31 µs. Event logging can still
perturb execution; these are supporting diagnostics, not replacement gate timings.

The original processing-1000 gap reverses under phase instrumentation, so its
phase totals are not presented as a faithful breakdown of the normal regression.
Instead, unchanged-binary scheduler controls test the specific prediction that
its gap should disappear without cross-capability migration:

| runWithMetrics-1000 profile | Release CPU µs | Candidate CPU µs | Change |
| --- | ---: | ---: | ---: |
| Default RTS, initial gate pair | 319.72 | 364.66 | +14.1% |
| Default capability count, migration disabled (`-qm`) | 245.55 | 240.15 | −2.2% |
| One capability (`-N1`) | 221.96 | 221.73 | −0.1% |

The prediction holds. Previous counter controls likewise reduced its gap to
about 3% with `-qm` or `-N1`. Neither setting is a proposed production default,
benchmark-gate change, or evidence that the default-profile regression is fixed.

## Mechanism and remaining uncertainty

Earlier bidirectional source isolation found that sharing the no-op provider
triggers the short-counter regression: restoring per-invocation creation in the
current runtime recovered that counter, and applying only sharing to the release
runtime introduced it. It did not establish that provider creation itself was
slow. The phase evidence now shows startup is cheap; the changed execution shape
leads to more expensive scheduling patterns during intake/drain.

GHC's `stg_forkzh` sets `context_switch` without immediately switching threads.
Nursery-block transitions check that flag, and the scheduler can distribute
runnable threads to idle capabilities. This provides a mechanism by which a
startup allocation/code-layout change can affect later migration. The exact heap
boundary or compiler-layout change responsible for selecting each pattern has
not been isolated. No claim is made that the shared tracer itself is contended,
that every deployment is slower, or that a particular atomic counter is at fault.

Dependency/source investigation used Mori first. GHC was not available in the
local registry search; its sources were verified at `ghc-9.12.4-release` upstream.
Canonical project: `mori://ghc/ghc` (artifact-level source URI pending). Relevant
project-relative sources are `rts/PrimOps.cmm`, `rts/HeapStackCheck.cmm`,
`rts/Schedule.c`, and `libraries/ghc-internal/src/GHC/Internal/Debug/Trace.hs`.
The [pinned runtime sources](https://github.com/ghc/ghc/tree/ghc-9.12.4-release/rts)
and [trace implementation](https://github.com/ghc/ghc/blob/ghc-9.12.4-release/libraries/ghc-internal/src/GHC/Internal/Debug/Trace.hs)
support those implementation details.

## Implementation decision

Keep the verified cancellation repair. No speculative performance patch is
retained. The previous provider rollback, tracing specializations, preparation
reordering and readiness wait did not yield a reliable whole-suite fix; the
[prior attempts](prior-fix-attempts.txt) record their failures. In particular,
waiting before processor setup moved migration to the processor rather than
removing the cost. Removing received-counter updates also did not support that
counter as the dominant cause.

The next performance implementation should target the owned producer/consumer
handoff and cross-capability synchronization, while preserving source and handler
effect ownership, cancellation, backpressure and ordering. The evidence does not
yet select a safe algorithm or justify pinning application threads, moving source
effects, adding artificial allocations, or changing production RTS defaults.
Any candidate must first improve both failing cases without worsening the six
controls, then pass the existing full benchmark gate and relevant correctness
checks. No additional acceptance requirements or thresholds are introduced here.

## Artifacts and reproduction

- [metadata.json](metadata.json) identifies commits, compiler, RTS, binary hashes,
  harness, dependency comparison and host limitations.
- [measurements.json](measurements.json) preserves every command, exit code,
  duration, CSV mean, two-standard-deviation estimate and allocation observation,
  including the perturbing diagnostic captures and repeat controls.
- [scheduler-evidence.json](scheduler-evidence.json) preserves parsed phase and
  scheduler evidence. It is separate from benchmark-gate results.
- [restoration.json](restoration.json) verifies clean source restoration and the normal
  rebuild. The rebuilt executable has a different checksum despite identical source
  and dependency unit IDs; no measurement is claimed for that new binary. Gate
  results above refer to the retained immutable candidate binary identified in metadata.
- Raw binaries, event logs, build logs, solver plans and parsers are retained at
  `/tmp/shibuya-phase-investigation`. Earlier isolation artifacts remain at
  `/tmp/shibuya-counter-rootcause-5zo0_ypk`; their principal outcomes are summarized
  above and in the prior-attempts artifact. Bulk binaries/event logs are not committed.

Build the current benchmark using the existing workflow:

```bash
nix develop --no-write-lock-file -c cabal build shibuya-core-bench:bench:shibuya-core-bench --enable-benchmarks
```

The release comparison binary was built from release core sources with the same
current package configuration and matched benchmark harness. Check dependency
unit IDs as well as versions before comparing; test-enabled solver plans may
select a different QuickCheck/Aeson dependency graph from benchmark-only plans.
Do not substitute an unmatched released benchmark fixture.

For an exact leaf, the recorded command shape is:

```bash
/path/to/release-bench -p '$0=="All.handler-overhead.io-handler.counter-100"' --stdev 3 --timeout 120 --csv /tmp/release.csv
/path/to/candidate-bench -p '$0=="All.handler-overhead.io-handler.counter-100"' --stdev 3 --timeout 120 --csv /tmp/candidate.csv --baseline /tmp/release.csv --fail-if-slower 10
```

Diagnostic event captures use `--timeout 20`, `+RTS -l -olPATH.eventlog -RTS`,
and either the unchanged binaries or explicitly labeled marker binaries.
Marker captures use `--stdev 5`; unchanged-binary scheduler captures use 3.
Scheduler controls use unchanged binaries and `--stdev 3 --timeout 120`, adding
only `+RTS -qm -RTS` or `+RTS -N1 -RTS`. Their exact commands are recorded in the
measurement artifact. None is counted as a release-gate pass.
