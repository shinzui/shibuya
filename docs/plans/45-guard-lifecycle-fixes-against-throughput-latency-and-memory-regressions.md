---
id: 45
slug: guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions
title: "Guard lifecycle fixes against throughput latency and memory regressions"
kind: exec-plan
created_at: 2026-09-20T04:11:26Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
master_plan: "docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:11:26Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:45:51Z
      verdict: "changes-requested"
      note: "Bench paths, executables and tasty-bench options verified; as listed the plan cannot complete before the plans it measures, which stalls plan selection without a two-pass protocol."
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Two-pass protocol with paused registry status; explicit dependency list without cancelled plan 42; three in-scope adapters."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T14:43:19Z
      mode: "implement"
      note: "Implemented pass-one lifecycle workloads and paired performance comparator"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T23:39:00Z
      mode: "implement"
      note: "Profiled and remediated candidate hot-path regressions before immutable pass-two capture"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T23:59:46Z
      mode: "implement"
      note: "Replace post-drain microtiming with mandatory public graceful-drain evidence"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T00:37:40Z
      mode: "implement"
      note: "Scope unmasking to owned actions and pass the affected 40-pair O2 candidate selection matrix."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T00:47:40Z
      mode: "implement"
      note: "Reject per-message serial unmasking and pass a 40-pair O2 serial-region selection matrix."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T03:00:00Z
      mode: "implement"
      note: "Completed live-adapter soaks, real-wire stress, high-cardinality measurement, and the aggregate candidate performance verdict."
---

# Guard lifecycle fixes against throughput latency and memory regressions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Catch performance regressions before release using reproducible baseline/candidate comparisons across the actual production runner, metrics, and adapters. A correctness fix is not cleared solely because it passes functional tests.


## Progress


- [x] (2026-09-20 14:48Z) Milestone 1: Capture matched baseline data before remediation.
- [x] (2026-09-20 14:43Z) Milestone 2: Extend production-runner and lifecycle performance workloads.
- [x] (2026-09-20 14:43Z) Milestone 3: Implement and test the statistical performance comparator.
- [x] (2026-09-22 04:53Z) Milestone 4: Measure fixed adapters and candidate soaks.
- [x] (2026-09-22 04:55Z) Milestone 5: Publish raw data and the candidate-bound performance verdict.


## Surprises & Discoveries


The original tasty-bench harness cannot be the release evidence format. It reports aggregate
benchmark statistics, but does not retain end-to-end latency samples, acknowledgement counts,
or one-process-per-sample GHC high-water marks. The new `lifecycle-load` executable therefore
runs exactly one production-runner scenario and writes one JSON sample. The existing tasty
suite imports the same scenario definitions for quick local regression feedback.

The metrics package does not yet expose the test harness that EP-39 will add for HTTP health
polling and real WebSocket subscriber churn. Pass one labels its internal registry-sampling
scenarios `health-poll-proxy` and `websocket-churn-proxy`, and the emitted JSON says
`core-proxy; ... belongs to EP-39`. This prevents proxy measurements from being mistaken for
wire-protocol evidence while still freezing the core load shape before remediation.

The guessed 2% idle CPU maximum was below the unmodified baseline. Ten samples per scenario
under both `-N1` and `-N4` measured idle CPU from 2.256% to 3.712%, while idle
`maxLiveBytes` ranged from 53,184 to 87,552 bytes. Before any candidate was observed, the
absolute limits were therefore calibrated to 4% CPU and 131,072 live bytes, with adverse
deltas of 1 percentage point and 32,768 bytes. The raw artifacts retain the measurements and
the budget file records the derivation.

2026-09-20: The first pass-two comparison was not valid release evidence. Version 1's
zero-delay scenarios were short enough that fixed process and nursery costs dominated
`allocatedBytesPerMessage` and `maxLiveBytes`; several runs did not cross enough 32 MiB nursery
collections for a stable ratio. Workload version 2 increases only the zero-delay message and
startup-cycle counts while preserving each scenario's queue, ordering, key distribution,
handler, and RTS configuration. Fixed-rate, timeout, and idle scenarios retain their original
durations.

2026-09-20: Optimized ticky profiles separated a real serial hot-path regression from the
short-run noise. Capturing the signal, intake wake cell, and full ingested envelope in nested
message closures added 72 bytes per message. An opaque boxed terminal publisher and direct
`MessageId` capture removed that cost without weakening the mandatory wake of idle intake.
The remaining 32 bytes per message and roughly 9-10% serial throughput loss came from EP-39's
per-burst atomic counter and CAS decrement. Sampler-observed idle-to-active transitions now
restamp `lastActivity`, all changed aggregate counters advance `lastProgress`, and the valid
completion path uses one fetch-and-add with a cold underflow repair. The final focused
20-pair N1 serial-full comparison measured a 0.99866 throughput adverse ratio and a 0.97588
allocation ratio; p95 and p99 ratios were 0.9985 and 0.9987. Live-heap and shutdown results
were too noisy at this scale and remain obligations of the full matrix and soak.

2026-09-20: The first full version-2 N1 capture exposed a second measurement defect. With 30
pairs, 80 cells passed, 12 remained inconclusive, and `serial-small-inbox` shutdown failed the
relative gate; however, the apparent 23.7% regression was a difference between one post-drain
`stopMaster` observation of roughly 11 and 14 microseconds. Every message-flow scenario waited
for completion before starting that timer, so none measured draining work. Workload version 3
adds `graceful-shutdown-drain`, which invokes public `runApp` and `stopAppGracefully` with a
bounded backlog and requires all 1,000 messages to finish and acknowledge. The unchanged 10%
shutdown budget applies to that scenario and repeated `startup-shutdown`; post-drain scenarios
retain their raw stop measurement but exclude it from verdicts. A smoke run measured a
meaningful 1.36-second drain in both baseline and candidate instead of microsecond noise.

2026-09-20: The first full version-3 N1 capture exposed one remaining real hot-path regression.
All eight failures had the same `Async 4`/`Unordered` shape across metrics-disabled,
metrics-enabled, health-poll-proxy, and websocket-churn-proxy: allocation was about 6.2% above
baseline and throughput was 7-8% lower. Optimized ticky profiles and a history bisect placed the
regression at the lifecycle masking change. NQE 0.6.6 registers children while masked; restoring
the whole processor made Streamly's unordered scheduler run unmasked and add per-item exception
bookkeeping. The selected implementation instead keeps framework coordination
`MaskedInterruptible` and uses `GHC.IO.unsafeUnmask` only around the owned adapter source and
message or batch action. The existing handler masking-state regression still observes
`Unmasked`, and all core, isolated-GC, and metrics tests pass. Forty alternating O2 N1 pairs for
the four affected scenarios pass all 20 measured cells: allocation adverse upper bounds are
1.03468-1.03662, and the tightest throughput upper bound is 1.04655 against the unchanged 1.05
limit. The rejected initial version-3 artifacts are not release evidence; the complete matrix
must be recaptured against the committed candidate.

2026-09-21: The first complete recapture against candidate `c25a9188` rejected a second
over-broad boundary in the opposite direction. Unmasking every serial message separately made
`serial-small-inbox` and `serial-full-inbox` throughput 9.7% and 11.7% worse than baseline;
their confidence intervals were wholly beyond the 5% gate. Serial execution has no concurrent
Streamly scheduler to protect, so the next candidate unmasks that processing region once and
uses per-action unmasking only for concurrent schedulers. A fresh 40-pair O2 N1 selection run
passes all ten serial cells: throughput adverse upper bounds are 0.98674 and 1.02400, allocation
is about 3.7% below baseline, and both live-heap intervals pass. The `c25a9188` full artifacts
remain rejected and must be replaced after the refined implementation is committed.

2026-09-21: Short live-service calibration exposed two harness concerns before final capture.
Comparing final process high-water heap to startup heap is not a retained-memory test: even an
eight-second healthy PGMQ run crossed additional nurseries and made that ratio exceed two. The
shared analyzer now forces a major collection at each sample, ignores the restart warmup, and
gates both first-versus-last retained-heap medians and the fitted retained-heap slope. Kafka's
first producer loop also unwound one blocking flush per produced message after stopping. Making
the stop branch perform exactly one flush removed the artificial post-run delay without changing
the recorded production or consumption workload.

2026-09-22: The first aggregate pass-two result became stale after the final scheduler masking
refinement. RC2 therefore rebuilt both sides from clean worktrees and recaptured every gate
rather than carrying the older verdict forward. Against released production SHA
`7512b5c692af1c005392e4445cfa26a9be41f9ea`, candidate SHA
`e28a95893a534a15302529850eea54f6e0682de0` passes all 84 N1 and all 84 N4 cells. Near-boundary
cells received 300 or 1,000 alternating pairs; no threshold changed and no waiver was used.

2026-09-22: REV-15-L1 remains measurable but is not removed. Fifty fresh high-cardinality
batch processes covering 1,000 through 50,000 distinct in-progress keys under N1 and N4
completed exactly. Over that finite range the conservative observed upper envelopes are 696
bytes/key under N1 and 649 bytes/key under N4, but key count is still not bounded by inbox
capacity. The release owner accepted that limitation for Shibuya 0.10.x with explicit calendar
and version expiry and caller-side cardinality controls; the performance result still does not
claim an implementation-enforced bound.


## Decision Log


2026-09-19: Performance evidence is a mandatory release gate with controlled paired comparisons; inconclusive results cannot be reported as no regression.

2026-09-20: Use one bounded scenario per `lifecycle-load` process. GHC's `max_live_bytes` is a
process high-water mark, so running multiple measured scenarios in one process would make later
samples inherit earlier peaks. Tasty-bench remains a developer signal; JSON process samples are
the comparator input.

2026-09-20: Keep HTTP health and WebSocket churn measurements explicitly at proxy fidelity until
EP-39 supplies its protocol harness. Recording a proxy as if it were an HTTP or WebSocket run
would be weaker than leaving the final matrix cell open.

2026-09-20: Treat the first N1/N4 capture as pre-remediation calibration, not final paired
evidence. It freezes the unmodified 0.9.0.3 behavior and calibrates near-zero absolute budgets,
but final release evidence must rebuild this exact production/harness identity and alternate its
runs with the candidate. The comparator rejects calibration artifacts marked
`pairedComparisonEligible: false` so they cannot accidentally certify a release.

2026-09-20: Revise the workload catalog to version 2 before freezing the pass-two candidate.
Both baseline and candidate use the same revised harness, so this is a measurement correction,
not a post-failure budget change. Require zero-delay scenarios to amortize process startup and
cross multiple configured nurseries; reject all version-1 pass-two artifacts rather than mixing
workload versions or presenting them as final evidence.

2026-09-20: Preserve terminal wakeup correctness while reducing closure retention. The hot read
remains a raw `ProcessorSignal`; terminal message actions retain one opaque
`ProcessorExitPublisher`, which owns publication plus the STM intake wake. A no-wake serial
experiment improved the same benchmark but failed the existing halt-wakes-idle-intake
regression, so it was discarded before candidate capture. Performance remediation may change
representation and cold-path placement, but may not restore an audited lifecycle defect.

2026-09-20: Use workload version 3 for final evidence and make its complete 17-scenario catalog
mandatory in the comparator. This does not change the 5%/10% limits or excuse the observed
version-2 result. It replaces an inapplicable post-drain timing with two stricter shutdown
measurements: 1,000 repeated cold startup/stops and a public graceful drain with live backlog.
The comparator now rejects even a mutually omitted baseline/candidate scenario, closing the
possibility that matching partial datasets could certify a release.

2026-09-20: Keep the supervisor's framework scheduler masked and restore normal interruptibility
only at owned user/adapter action boundaries. This preserves exception-safe registration,
linking, publication, and cleanup while avoiding the Streamly unordered scheduler's unmasked
per-item cost. `unsafeUnmask` is confined to the ingester source and individual message/batch
actions; it does not surround ownership transfer or the scheduler. The original budgets remain
unchanged. Because 20 pairs left two affected throughput intervals barely inconclusive, use 40
pairs for candidate selection and the final near-boundary N1 cells rather than weakening the 5%
gate.

2026-09-21: Unmask each serial processing region once, because it has no concurrent scheduler
whose exception bookkeeping must remain masked. Ahead, Async, and partitioned schedulers stay
masked and unmask only individual actions; the adapter source remains an owned unmasked region.
This concurrency-specific boundary passes the two 40-pair serial scenarios while retaining the
four 40-pair concurrent results. It changes neither the lifecycle contract nor any budget.

2026-09-21: Use one common live-adapter evidence schema and analyze current retained heap after
forced major collections, not the monotonic process high-water mark, for sustained-growth
decisions. Keep `max_live_bytes` as a reported ceiling. The precommitted retained tolerance is
the larger of 262,144 bytes and 5% of the first post-restart window median; both net median growth
and linear slope across the remaining window must fit that tolerance. Sustainable and saturation
runs last 120 seconds with a midpoint restart; every adapter also gets its own 1,800-second soak.
Calibration selected 2/20 msg/s for Kafka and 20/200 msg/s for PGMQ and Kiroku as the respective
sustainable/saturation targets. These choices and exact fixture identities were recorded before
the retained captures.

2026-09-21: Treat the high-cardinality result as an empirical finite-source envelope, not a
production resource bound. Record every raw sample and the conservative upper envelope, keep
REV-15-L1 open, and require EP-44 to obtain the human disposition demanded by the release plan.

2026-09-22: Replace the stale pass-two aggregate with a clean-source RC2 capture. The baseline
and candidate use the same historical harness overlay, GHC 9.12.4, O2, `-A32m`, and normalized
external dependency solution. Preserve all rejected diagnostics separately. The release verdict
may use only the RC2 N1/N4 results, nine RC2 live-adapter summaries, RC2 real-wire captures, and
RC2 high-cardinality envelope indexed by the RC2 performance verdict.


## Outcomes & Retrospective


Pass one is complete and paused. It has a compiled production-runner workload catalog, a
deterministic paired bootstrap comparator, and 320 raw pre-remediation samples: ten runs for
each of 16 scenarios under both `-N1` and `-N4`, with zero dropped acknowledgements. The
comparator's eight synthetic tests prove pass, fail, inconclusive, environment-mismatch,
dropped-work, mandatory-scenario, absolute-budget, deterministic-seed, and calibration-misuse
behavior. No candidate
performance verdict exists yet; pass two must recapture this baseline in alternating order with
the integrated candidate.

Pass two is complete for RC2. The clean-worktree N1 and N4 datasets pass all 84 measured cells
in each verdict without a threshold change or waiver. Kafka, PGMQ, and Kiroku each pass
sustainable, saturation, and 1,800-second midpoint-restart runs against live services. The soak
totals are respectively 3,594, 34,473, and 34,671 messages with exact identity-ledger completion,
zero duplicates, missing, unexpected, or malformed deliveries, zero failures, zero final durable
backlog, and no sustained retained-heap growth. Real-wire stress completes 100,000 readiness
requests and 10,000 WebSocket connection cycles with zero errors or leaked connection slots.
The 50-process high-cardinality capture reports the finite memory envelope while preserving the
accepted unbounded-key limitation. The indexed machine-readable result is
`docs/audits/lifecycle-release/artifacts/candidate-0.10.0.0-rc2/performance/candidate-performance-verdict.json`.


## Context and Orientation


The existing harness is shibuya-core-bench/bench/Main.hs with Bench/HotPath.hs, Framework.hs, Concurrency.hs, Baseline.hs, Handler.hs and DeadLetterReason.hs under that directory. shibuya-core-bench/bench/Test/ProdStress.hs exercises the production runner; some existing finite-stream helpers instead size their inbox to the whole input and cannot demonstrate bounded-backpressure behavior. shibuya-core-bench/README.md documents CSV baselines and allocation reporting. Existing docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md owns dependency-bound policy and release-skill changes. This plan adds broader lifecycle performance assurance, without duplicating that ownership.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

When this plan was drafted no local docs/adr corpus existed in the Shibuya repository; its first record, docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md, was added on 2026-09-20. It concerns linked threads and garbage-collection liveness tests and does not constrain benchmarks. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 freezes a baseline before remediation. Record the latest released source verified against tags/registry and the pre-remediation audit source separately; do not call a local version bump a published release. Build baseline and candidate with identical compiler, optimization, RTS flags, package solution, service versions and machine settings. Compare dependency-only changes separately on identical source. Port new harness-only scenarios to isolated baseline worktrees where needed, preserving measured production code and recording the patch hash. Record unsupported or hanging baseline scenarios as correctness failures, not infinitely good/poor performance. Pin fixture sizes, seeds, message payloads, key distributions and service resources. Capture baseline data before accepting hot-path fixes, even though the final candidate comparison comes later.

Milestone 2 adds Bench/Lifecycle.hs and a production load executable under shibuya-core-bench/bench/Test/, wired in shibuya-core-bench/shibuya-core-bench.cabal. Cover Serial, Ahead, Async, partitioned hot-key/uniform-key/high-cardinality workloads, small/full inboxes, size/time batching, idle workers, repeated startup/shutdown, retry and DLQ paths, metrics disabled/enabled, health polling, and WebSocket subscriber churn. Measure messages/second, end-to-end p50/p95/p99 latency, allocated bytes/message, live heap/RSS, GC time, idle CPU and shutdown latency. Use fixed-rate arrivals below and near measured saturation and timestamp from scheduled arrival so queueing delay is not hidden. Do not equate benchmark-operation runtime with message p99. Count completed/acknowledged work to reject benchmarks that get faster by dropping messages. New executables expose documented machine-readable output and bounded runs.

Milestone 3 adds scripts/audit/compare-performance.ts with fixtures and Bun tests. Use at least ten alternating baseline/candidate measured runs after warmup on a quiet fixed machine, paired by workload and RTS configuration (-N1 and a fixed multicore count such as -N4). Report paired ratios and 95% confidence intervals using a documented reproducible resampling seed. Default release budgets are at most 5% throughput loss, 10% p95/p99 or shutdown-latency increase, and 5% allocation/live-memory increase per matched scenario. A confidence interval whose adverse upper bound exceeds the budget cannot pass: overlapping/too-wide intervals are inconclusive and require more samples or a less noisy runner, not a waiver. Establish absolute idle CPU and idle-memory budgets from baseline repeatability before measuring the candidate; near-zero denominators require absolute deltas. Zero sustained memory growth after warmup at a fixed bounded workload and no busy-spin are mandatory regardless of percentage comparisons. Preserve any stricter existing project budgets. Record these initial policy choices in the evidence manifest; changing them after a failed run requires a named human release-owner decision with rationale.

Milestone 4 measures the three in-scope adapters, Kafka, PGMQ and Kiroku, against their live ephemeral services using fixtures owned by their remediation plans. The MessageDB adapter is deprecated and excluded. Separate broker/database bottlenecks from core overhead with both mock/no-op and real-service runs; run at baseline sustainable load as well as saturation. Include a 30-minute steady-state/stop-restart soak, record queue depth and backlog, and fit retained-memory trend after warmup. Performance harness development and baseline capture can proceed alongside remediation; final measurements require the integrated candidate SHAs. Each fix touching hot paths must supply a focused before/after measurement before acceptance, followed by the full matrix here. If a regression appears, profile the affected path, fix it and rerun correctness tests as well as benchmarks. Do not restore an unsafe implementation to meet a budget.

Milestone 5 publishes matched raw data, summaries, machine metadata and a machine-readable verdict consumed by the release validator. Run the gate for all lifecycle and runtime-dependency changes regardless of patch/minor version. Coordinate any release-skill edit through the existing dependency-bound plan's owner. Keep noisy shared-runner smoke tests distinct from controlled release measurements.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
cabal build shibuya-core-bench:lifecycle-load shibuya-core-bench:bench:shibuya-core-bench
cabal run shibuya-core-bench:lifecycle-load -- --list
cabal run shibuya-core-bench:lifecycle-load -- \
  --scenario serial-small-inbox \
  --sample-id smoke-serial \
  --messages 200 \
  +RTS -N1 -T -RTS
bun test scripts/audit/compare-performance.test.ts
bun scripts/audit/capture-performance-baseline.ts \
  --executable "$(cabal list-bin shibuya-core-bench:lifecycle-load)" \
  --output docs/audits/lifecycle-release/artifacts/baseline-0.9.0.3/pre-remediation-n1.json \
  --label baseline-0.9.0.3-n1 --rts -N1 --iterations 10 \
  --machine-id MacBookPro18,2 --platform Darwin-arm64 \
  --compiler ghc-9.12.4 --optimization O2 --capabilities 1 \
  --production-sha 7512b5c692af1c005392e4445cfa26a9be41f9ea \
  --harness-sha 886f5910a5f1a47b5465dce9380bce831467fe2b \
  --solver-plan-hash 47f9680ce1ad6be1220c85dfc30c850d097e20d4e97bef9d4394cbce30ec4dc4
cabal bench shibuya-core-bench --benchmark-options="--stdev 5 --timeout 300 --csv baseline.csv"
cabal run shibuya-core-bench:prod-stress
# In a matched candidate worktree, after capturing the baseline:
cabal bench shibuya-core-bench --benchmark-options="--stdev 5 --timeout 300 --csv candidate.csv"
bun test scripts/audit/compare-performance.test.ts
bun scripts/audit/compare-performance.ts --baseline baseline.json --candidate candidate.json --budgets docs/audits/lifecycle-release/performance-budgets.json
```

The first build command succeeds under GHC 9.12.4. The comparator test command reports eight
passing tests. The smoke command emits one JSON object whose `expected`, `completed`, and
`acknowledged` values are all 200. The two capture commands, differing only in `--rts`,
`--capabilities`, `--label`, and output name, wrote 160 samples each and no sample lost work.
The command substitution shown above is for a human shell; the recorded run used the exact
path printed by `cabal list-bin`. Successful suites exit zero and report executed tests; zero
tests or skipped services are not acceptance. Record exact selectors and fixture commands in
this section when the harness is extended.


## Validation and Acceptance


All mandatory workloads have matched evidence and satisfy both statistical and absolute budgets. The comparator rejects synthetic throughput, tail-latency, allocation and memory regressions, missing scenarios, different environments and inconclusive data. Candidate soaks have no sustained retained-memory growth, orphan workers or idle busy-spin. Raw data supports every verdict; aggregate improvements cannot hide an individual critical-path regression.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependency: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md. Soft dependencies, for final measurements and not initial baseline work: docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md, docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md, docs/plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries.md, docs/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults.md and docs/plans/43-make-kiroku-subscription-ownership-exception-safe.md. Plan 42 is cancelled.

This plan runs in two passes. Pass one is Milestones 1 through 3. When they are done, stop, and set this plan's status in the parent MasterPlan's registry to In Progress with the note "paused after Milestone 3; resumes when EP-38, EP-39, EP-40, EP-41 and EP-43 are Complete". Whoever picks the next plan to implement must skip this one while it is paused, even though it is listed first and is In Progress; otherwise the selection rule, first plan whose hard dependencies are complete and which is not finished, would choose it forever. Pass two is Milestones 4 and 5 and begins only when those five plans are Complete. They in turn cannot close before pass one is finished, because each must take focused before/after measurements with this plan's harness. This plan owns benchmark code, performance scenario definitions, budgets and comparator; adapter plans own their service fixtures. It produces the performance verdict required by docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md. The JSON comparator inputs and CLI are new interfaces, to be specified and tested here; CSV alone does not contain latency distributions. EP-37 owns evidence schema and receives additive performance fields. No package release or benchmark-policy weakening is authorized.


## Revision Notes


2026-09-20 UTC: Revised after a pre-implementation review of the parent MasterPlan. Defined the two-pass protocol and its paused registry status, because as drafted this plan was listed ahead of the plans it must measure and could not finish until they did, which would have stalled plan selection. Replaced the dependency range that included the cancelled MessageDB plan with an explicit list, scoped adapter measurement to the three in-scope adapters, and noted the repository's new first ADR.

2026-09-20 UTC: Implemented the pass-one workload and comparator interfaces. Added a shared
production-runner scenario catalog, a one-scenario JSON load executable, precommitted budgets,
and a deterministic paired bootstrap comparator with synthetic negative controls. Baseline data
capture remained open so the harness could be committed first and its exact SHA recorded.

2026-09-20 UTC: Completed pass one. Captured ten fresh-process samples for all 16 scenarios under
both N1 and N4 against production SHA `7512b5c692af1c005392e4445cfa26a9be41f9ea`, harness
SHA `886f5910a5f1a47b5465dce9380bce831467fe2b`, and solver hash
`47f9680ce1ad6be1220c85dfc30c850d097e20d4e97bef9d4394cbce30ec4dc4`; calibrated the
absolute idle budgets from those results; and marked the raw data ineligible for the later final
paired verdict so pass two must alternate baseline and candidate processes.

2026-09-20 UTC: During pass-two candidate selection, rejected version-1 measurements whose
short zero-delay runs made fixed allocation and live-heap costs dominate. Version 2 lengthens
those workloads symmetrically for baseline and candidate. Optimized ticky profiles then found
and removed per-message closure retention and EP-39 activity-accounting atomics while preserving
idle-intake wakeup correctness. A 20-pair focused N1 serial-full comparison passes the original
budgets; the immutable all-scenario N1/N4 capture, live services, and soak remain open.

2026-09-20 UTC: Rejected the first full version-2 N1 capture after 30 pairs showed that ordinary
scenario shutdown values were single post-drain 8-90 microsecond observations, not drain
latency. Version 3 adds a public `runApp`/`stopAppGracefully` workload with a bounded live
backlog, keeps repeated startup/stop coverage, excludes the inapplicable one-shot values from
other scenario verdicts, and requires the complete 17-scenario catalog. The 10% shutdown budget
is unchanged; both baseline and candidate compile and acknowledge all 1,000 messages in the new
smoke workload.

2026-09-20 UTC: Rejected the first full version-3 N1 candidate after it exposed a consistent
unordered `Async 4` regression rather than measurement noise. A bisect and optimized ticky
profiles traced it to restoring the whole NQE child to `Unmasked`, which made Streamly pay
exception bookkeeping per item. The candidate now keeps framework coordination masked and
unmasks only adapter and message/batch actions. The 236-example core suite, both isolated GC
suites, the 48-example metrics suite, and all eight comparator tests pass. Forty alternating O2
N1 pairs across the four affected scenarios pass all 20 focused cells without a budget change;
the complete N1/N4 recapture, live services, and soak remain open.

2026-09-21 UTC: Completed pass two. Published the passing complete N1/N4 paired verdicts, nine
passing live-service summaries including one 1,800-second restart soak per adapter, real HTTP and
WebSocket stress artifacts, the REV-15-L1 high-cardinality envelope, and one indexed aggregate
performance verdict. No threshold changed and no waiver was used. REV-15-L1 remains open because
measurement does not bound the implementation's distinct in-progress key count; EP-44 owns its
human release disposition.

2026-09-21 UTC: Rejected the first full recapture against `c25a9188` because per-message
unmasking introduced confident 9.7% and 11.7% serial throughput regressions. The refined
candidate unmasks each serial region once while leaving concurrent schedulers masked and their
owned actions unmasked. All core and isolated-GC tests pass, and a fresh 40-pair O2 N1 focused
comparison passes all ten serial cells; the full committed-candidate recapture remains open.

2026-09-22 UTC: Replaced every stale performance artifact with the exact RC2 capture at
`e28a95893a534a15302529850eea54f6e0682de0`. Both paired matrices pass 84/84 cells; all nine
live-service cells pass with discrepancy-free external ledgers; real-wire health and WebSocket
loads pass; and 50 high-cardinality processes establish the finite 696-byte/key N1 and
649-byte/key N4 envelopes. The aggregate verdict records the release owner's bounded
REV-15-L1 acceptance. No budget changed and no waiver was used.
