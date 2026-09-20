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
---

# Guard lifecycle fixes against throughput latency and memory regressions

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Catch performance regressions before release using reproducible baseline/candidate comparisons across the actual production runner, metrics, and adapters. A correctness fix is not cleared solely because it passes functional tests.


## Progress


- [ ] Milestone 1: Capture matched baseline data before remediation. The 0.9.0.3 production SHA, compiler and platform are identified; controlled N1/N4 sample capture remains.
- [x] (2026-09-20 14:43Z) Milestone 2: Extend production-runner and lifecycle performance workloads.
- [x] (2026-09-20 14:43Z) Milestone 3: Implement and test the statistical performance comparator.
- [ ] Milestone 4: Measure fixed adapters and candidate soaks.
- [ ] Milestone 5: Publish raw data and the candidate-bound performance verdict.


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


## Decision Log


2026-09-19: Performance evidence is a mandatory release gate with controlled paired comparisons; inconclusive results cannot be reported as no regression.

2026-09-20: Use one bounded scenario per `lifecycle-load` process. GHC's `max_live_bytes` is a
process high-water mark, so running multiple measured scenarios in one process would make later
samples inherit earlier peaks. Tasty-bench remains a developer signal; JSON process samples are
the comparator input.

2026-09-20: Keep HTTP health and WebSocket churn measurements explicitly at proxy fidelity until
EP-39 supplies its protocol harness. Recording a proxy as if it were an HTTP or WebSocket run
would be weaker than leaving the final matrix cell open.


## Outcomes & Retrospective


Pass one now has a compiled production-runner workload catalog and a deterministic paired
bootstrap comparator. The Haskell smoke matrix completed every expected delivery and
acknowledgement across concurrency, partition, batching, retry, dead-letter, idle, observer and
startup scenarios. The comparator's six synthetic tests prove pass, fail, inconclusive,
environment-mismatch, dropped-work, absolute-budget and deterministic-seed behavior. Baseline
capture remains before pass one can pause; no candidate performance verdict exists yet.


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
cabal bench shibuya-core-bench --benchmark-options="--stdev 5 --timeout 300 --csv baseline.csv"
cabal run shibuya-core-bench:prod-stress
# In a matched candidate worktree, after capturing the baseline:
cabal bench shibuya-core-bench --benchmark-options="--stdev 5 --timeout 300 --csv candidate.csv"
bun test scripts/audit/compare-performance.test.ts
bun scripts/audit/compare-performance.ts --baseline baseline.json --candidate candidate.json --budgets docs/audits/lifecycle-release/performance-budgets.json
```

The first build command succeeds under GHC 9.12.4. The comparator test command reports six
passing tests. The smoke command emits one JSON object whose `expected`, `completed`, and
`acknowledged` values are all 200. Successful suites exit zero and report executed tests; zero
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
capture remains open so the harness can be committed first and its exact SHA recorded.
