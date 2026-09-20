---
id: 40
slug: prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries
title: "Prevent Kafka acknowledgements from skipping unresolved deliveries"
kind: exec-plan
created_at: 2026-09-20T04:05:13Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
master_plan: "docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:05:13Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:45:51Z
      verdict: "comments"
      note: "REV-10 claims re-verified at unchanged adapter HEAD; hard dependency on core is not genuine for the barrier fix; adapter pins shibuya-core ^>=0.9.0.1."
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Core plan becomes a soft dependency gating only terminal-ack visibility; record core 0.9 bound handling."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T20:15:00Z
      mode: "implement"
      note: "Begin implementation after EP-39 completion; resolve adapter and Kafka dependencies through Mori before changing acknowledgement state."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-20T23:10:00Z
      mode: "implement"
      note: "Complete delivery and assignment fencing, terminal failure propagation, live-broker recovery evidence, capability documentation, and focused performance comparison."
---

# Prevent Kafka acknowledgements from skipping unresolved deliveries

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Prevent Kafka commits from crossing unresolved deliveries, and surface acknowledgement failures even when ingestion has already stopped.


## Progress


- [x] (2026-09-20 22:20Z) Milestone 1: Reproduce acknowledgement interleavings with a reference model.
- [x] (2026-09-20 22:31Z) Milestone 2: Fix unresolved-delivery tracking and terminal failure propagation.
- [x] (2026-09-20 23:04Z) Milestone 3: Verify recovery and reassignment against a live ephemeral broker.


## Surprises & Discoveries


2026-09-20: Implementation starts from the unchanged reviewed adapter SHA
`6c0cd3fc840c9f5ba48558ca94c7d826a3da6c9f`. Mori resolves the owner as
`mori://shinzui/shibuya-kafka-adapter`, with `mori://shinzui/kafka-effectful` and
`mori://haskell-works/hw-kafka-client` as the relevant consumer API sources. The adapter
checkout is clean and the core finalizer-failure contract needed for terminal acceptance is
already complete, so no soft-gated work remains.

2026-09-20: The unchanged baseline fails both promoted regressions. Buffered retries for
offsets 42 then 43 seek `[42, 43]`, proving that the later callback replaces the earliest
recovery boundary, and an acknowledgement operation that exhausts its retry budget returns
normally instead of throwing. The test-only baseline patch and exact failures are retained in
`docs/audits/lifecycle-release/artifacts/ep40-kafka-lifecycle/baseline-red.log`.

2026-09-20: A live buffered-retry test initially waited for both replayed records before
acknowledging either. It correctly blocked after the first replay because the repaired barrier
must filter its successor until that replay succeeds. A single stateful stream fold that acks
the boundary replay before awaiting its successor expresses the intended protocol and passes.

2026-09-20: Throwing through `Error KafkaError` was not sufficient for terminal acknowledgement
visibility: that effect is interpreted around the consumer, outside core's synchronous
finalizer boundary. A typed synchronous exception reaches EP-38's retained failure path and
produces `LifecycleFailed` even after the source has ended.

2026-09-20: The actual-reassignment fixture observed librdkafka's BeforeAssign/Assign and
BeforeRevoke/Revoke callback sequence with two consumers in one group. A callback retained by
the revoked owner could not store; restarting the group recovered that partition's payload.

2026-09-20: `nix flake check` exposes an unrelated pre-existing package-output defect: the
generated `callCabal2nix` receives the repository root although the Cabal package is in the
`shibuya-kafka-adapter/` subdirectory. Formatting, Cabal tests, and strict capability validation
pass. The package-output failure is retained for EP-44's candidate-build gate rather than being
misreported as an EP-40 pass.


## Decision Log


2026-09-19: Prove the commit boundary against unresolved deliveries and assignment identity; numeric offset adjacency is not a correctness assumption.

2026-09-20: Use a monotonic delivery token plus a per-partition assignment generation. The
earliest unresolved offset and the token that requested its retry form the recovery barrier;
only a newer replay at that offset may clear it. Successful duplicate finalization is a no-op,
while failed or cancelled finalization remains retryable.

2026-09-20: Make reassignment fencing opt-in through the existing `kafkaRebalanceHandler`
surface. `kafka-effectful` requires callbacks before consumer construction, so silently
installing one inside `kafkaAdapter` is impossible; callers share state through
`kafkaAdapterWith` when they need old-owner fencing.

2026-09-20: Surface exhausted store, seek, or pause operations as public
`KafkaAcknowledgementException` synchronous exceptions. Retain the fatal slot for source
diagnostics, but do not depend on a future poll for correctness.

2026-09-20: Keep Kafka's absence of a DLQ producer as a deliberate capability boundary.
`AckDeadLetter` continues to warn and store the offset; a nonexistent producer-failure path is
documented as not applicable rather than simulated and claimed as broker evidence.


## Outcomes & Retrospective


Completed at adapter implementation SHA `554c969b1d95842628d0483f7ae6331c87249a84`
and documentation/ADR SHA `796dc07238a053c5f114993fc9763e72f04d7b51`.
Delivery-token barriers preserve the earliest unresolved record, assignment generations fence
old-owner callbacks when the documented rebalance helper is installed, and exhausted
acknowledgement operations reach core as retained processor failures. The final adapter suite
passes 53 cases, including 13 live-broker integrations and all five mandatory Kafka persistence
matrix cells.

Ten alternating baseline/candidate runs of the unchanged live AckRetry workload measured a
mean paired latency change of +0.123% with a 95% bootstrap interval of -0.117% to +0.334%,
inside EP-45's 10% focused latency budget. This is child-plan evidence, not the final integrated
performance verdict. The capability contract and changelog now name the opt-in rebalance fence,
serial-only processing, deliberate DLQ drop behavior, and direct terminal exception. The
durable state-machine rationale lives in
`mori://shinzui/shibuya-kafka-adapter` at
`docs/adr/0001-fence-acknowledgements-by-delivery-and-assignment.md` because an artifact-level
ADR URI is not registered yet.


## Context and Orientation


The owning repository is mori://shinzui/shibuya-kafka-adapter; all paths in this paragraph are relative to that project (artifact-level source URIs pending). shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs and Kafka.hs implement retry barriers and acknowledgements; test/Shibuya/Adapter/Kafka/AckHandleTest.hs and IntegrationTest.hs under the package, plus test/Kafka/TestEnv.hs, provide mock and broker fixtures. REV-10 in the Shibuya review bundle records a source-derived interleaving: buffered offset 42 retries, 43 retries and replaces the barrier, then successful 43 clears it and can permit committing past unresolved 42. It also records ackAttempt setting fatalError while returning success; only a future source read notices, which may never happen during shutdown. Kafka presently requires Serial processing; this plan does not silently expand supported concurrency. On 2026-09-20 the adapter repository's HEAD was still the reviewed commit 6c0cd3f, and the named files, the unconditional `Map.insert` of the retry barrier in `mkAckHandle`, the barrier deletion in `storeGuarded` and the `fatalError` slot were all confirmed present there; recheck before starting.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

When this plan was drafted no local docs/adr corpus existed in the Shibuya repository; its first record, docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md, was added on 2026-09-20. It concerns linked threads and garbage-collection liveness tests in core and does not constrain this adapter. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 adds a small per-partition reference model and deterministic tests in AckHandleTest.hs for buffered offsets 42 and 43, repeated Retry, out-of-order callbacks, duplicate acknowledgement and shutdown after source completion. In the model, the safe commit boundary cannot cross any unresolved delivered offset; gaps in actual Kafka offsets do not themselves imply missing deliveries. Reproduce or disprove each source-derived finding before claiming a fix. Run model sequences with fixed recorded seeds.

Milestone 2 replaces the single overwriteable retry barrier with state that preserves the earliest unresolved delivery and distinguishes stale buffered callbacks from replayed attempts. Specify attempt identity and partition ownership explicitly. If a single earliest-offset barrier suffices, prove it against the reference model; otherwise use an ordered unresolved-delivery ledger. Seeking and clearing state must never discard an earlier retry obligation. Failed terminal acknowledgement must throw or otherwise reach core's terminal failure path directly, rather than rely exclusively on a later kafkaSource read. The adapter half of this, throwing from the finalizer instead of parking the error in `fatalError`, can be written and unit-tested now. Its end-to-end acceptance, that the application sees the failure, is gated on Milestone 3 of docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md: until that lands, core converts an exhausted finalizer into a graceful halt and the failure would still vanish. The retry-barrier fix in this milestone is not gated on anything in core. Keep retryable errors retryable and duplicate finalization safe.

Milestone 3 extends IntegrationTest.hs and Kafka/TestEnv.hs with ephemeral-broker cases: retry while later records are buffered, disconnect during store/commit, DLQ producer failure, cancel while finalizing, stop/drain/consumer-close ordering, restart and partition reassignment with late callbacks. Observe broker-committed offsets after restart, not just mock calls. Fence callbacks from revoked assignments or demonstrate an existing upstream fence with tests; no static-membership feature is required. Document deliberate drop behavior when no DLQ producer is configured. Broker faults must be confined to the test fixture.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
mori registry show shinzui/shibuya-kafka-adapter --full
mori registry docs shinzui/shibuya-kafka-adapter
mori registry search kafka-effectful
mori path mori://shinzui/shibuya-kafka-adapter
# Change to the resolved project root, then:
cabal test shibuya-kafka-adapter --test-show-details=direct
```

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.

The accepted implementation used the following exact selectors in the Mori-resolved adapter
checkout, with an ignored local package entry for the exact candidate core:

```bash
nix develop -c cabal test shibuya-kafka-adapter-test --test-options='-p AckHandle' --test-show-details=direct
nix develop -c cabal test shibuya-kafka-adapter-test --test-options='-p Integration' --test-show-details=direct
nix develop -c cabal test all --test-show-details=direct
okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
```

The first command passes 16 cases, the live group passes 13, and the full suite passes all 53.
The Redpanda endpoint was already running locally; tests created unique topics and group IDs and
did not reset or stop the shared service. Focused performance alternated the baseline and
candidate test binaries for ten pairs of `AckRetry redelivers within the same session`; raw
samples and the deterministic bootstrap result are retained under
`docs/audits/lifecycle-release/artifacts/ep40-kafka-lifecycle/`.


## Validation and Acceptance


Offset 43 cannot make offset 42 disappear from the recovery obligation. On restart every unresolved record is redelivered or remains durably recoverable; a terminal ack failure after source exhaustion is visible to waitApp. Repeated callbacks do not double-advance offsets. Reassignment rejects stale acknowledgements. Both mock model tests and actual broker tests pass against the same candidate core solution.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependency: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md. Soft dependency: docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md; this plan starts as soon as the evidence plan is complete, and only the terminal-acknowledgement visibility acceptance waits for the core plan's Milestone 3. This plan cannot be marked Complete until that acceptance has run against the completed core milestone. The contract to assume meanwhile is decided: infrastructure finalization failure is a processor failure, not a Halt. All production adapter changes belong to mori://shinzui/shibuya-kafka-adapter; request required cross-workspace write approval before editing. Use a temporary Cabal project including the exact candidate core, not a separately installed older core. The adapter's committed Cabal file bounds shibuya-core as `^>=0.9.0.1`, and the candidate core is expected to carry a new major version because the core plan adds constructors to exported error types. Build against the candidate in a temporary Cabal project that lists the candidate core checkout and this adapter as packages and relaxes only that bound, for example with `allow-newer: shibuya-kafka-adapter:shibuya-core`; never commit the relaxation. Change the committed bound once, in the adapter's repository and as part of this plan, when Milestone 1 of docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md fixes the candidate core version with the release owner, because final evidence must come from clean committed sources. This plan owns Kafka delivery state and broker fixtures; it consumes core finalizer failure semantics. Existing dependency-bound/release work remains owned by docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md. Record exact project-relative test selectors and service setup from the existing harness before running; do not treat skipped integration tests as success.


## Revision Notes


2026-09-20 UTC: Revised after a pre-implementation review of the parent MasterPlan. The core lifecycle plan changed from a hard to a soft dependency: the retry-barrier defect, which can commit past an unresolved offset, needs nothing from core, so only the acceptance that a terminal acknowledgement failure is visible to the application is gated, on the core plan's Milestone 3. Recorded that the adapter pins shibuya-core to the 0.9 series and how to build against a major-version candidate without committing a relaxed bound. Recorded that the review's source claims were re-verified against the adapter's unchanged HEAD, and noted the Shibuya repository's new first ADR.

2026-09-20 UTC: Started EP-40 after EP-39 completed. Resolved the clean adapter checkout and
its Kafka dependencies through Mori, confirmed the reviewed baseline SHA, and confirmed that
EP-38's terminal finalizer-failure contract is available for end-to-end acceptance.

2026-09-20 UTC: Completed EP-40. Reproduced REV-10-F1 and REV-10-F2 against the reviewed
baseline; implemented delivery-token, earliest-barrier, per-handle idempotence, typed terminal
failure, and assignment-generation fencing; passed deterministic and live-broker recovery,
restart, cancellation, timeout, repeated-stop, and actual reassignment cases; recorded the
adapter ADR/capability changes and focused paired performance evidence. The pre-existing broken
Nix default-package output remains explicit for EP-44 rather than being hidden by the passing
Cabal and OKF checks.
