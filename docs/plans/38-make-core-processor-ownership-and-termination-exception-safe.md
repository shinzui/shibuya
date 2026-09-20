---
id: 38
slug: make-core-processor-ownership-and-termination-exception-safe
title: "Make core processor ownership and termination exception safe"
kind: exec-plan
created_at: 2026-09-20T04:05:12Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
master_plan: "docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:05:12Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:45:51Z
      verdict: "changes-requested"
      note: "Claims match source; orientation omitted Master/BatchProcessor/Ingester and three suites, left IR-6 total shutdown deadline and per-strategy failure observability undecided, and new error constructors are a deliberate breaking change."
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Add omitted modules and suites, total shutdown bound, per-strategy failure observability, deliberate error-constructor break; boundary with standalone EP-46; now a soft dependency of metrics and adapter plans."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T14:55:33Z
      mode: "implement"
      note: "Begin implementation from audited lifecycle defects; add deterministic regressions before changing ownership, termination, and snapshot contracts."
---

# Make core processor ownership and termination exception safe

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


Make application startup, failure, halt, and shutdown predictable: no registered worker is lost, no empty-inbox halt hangs, and infrastructure failure cannot masquerade as successful completion.


## Progress


- [x] Milestone 1: Add deterministic regressions for ownership, halt, failures and policies.
- [x] Milestone 2: Fix exception-safe resource acquisition and cleanup, and decide the total shutdown bound.
- [x] Milestone 3: Make stop/failure wakeups and scheduler ownership reliable.
- [ ] Milestone 4: Validate capacities, publish the terminal snapshot and verify all core/GC regressions.


## Surprises & Discoveries


2026-09-20: The existing UnliftIO `catch`/`tryAny` helpers intentionally exclude asynchronous exceptions, exactly as REV-3 reported. `Effectful.Exception.mask`, `try`, and `trySync` supply the needed split: ownership transfer catches cancellation, while the adapter-shutdown loop catches only synchronous failures so an external cancellation or total deadline cannot be mistaken for another adapter failure and swallowed.

2026-09-20: The batch ticker concern in REV-15 was a real ownership gap even though no supported configuration had naturally thrown from the ticker. The output loop observed only the consumer async, so a ticker exception could leave it waiting forever. `pollSTM` now makes ticker failure one of the output loop's STM wake sources, and an internal tick hook gives the regression a deterministic fault-injection point without changing the public API.

2026-09-20: One shutdown coordinator is necessary in addition to exception-safe cleanup. Without it, two correct callers could concurrently invoke every adapter twice. `AppHandle` now retains the first caller's result in a `TMVar`; later callers see the same success, forced-shutdown result, or exception.

2026-09-20: A deterministic startup-cancellation regression required the ownership transfer itself to be injectable without exposing a stable public hook. The generic `acquireOwned` primitive therefore lives in the explicitly unstable `Shibuya.Internal.App` module. `runApp` uses that exact primitive, and the test pauses its acquired action on an STM barrier, cancels it, and observes cleanup before the cancellation is classified and rethrown by `runApp`.

2026-09-20: The first focused EP-45 run caught a real keyed hot-path regression before acceptance. Recurring through `restore loop` inside each masked worker transfer retained one exception-restore frame per item, reducing the hot-key workload to 25%--45% of baseline throughput. The transfer now leaves `mask_` before tail-recurring, retaining the cancellation guarantee without the frame chain. The same run exposed that spawning the supervisor with plain `async` under `mask_` made the long-lived child inherit the masked state and added about 1.5 KiB per startup cycle. `asyncWithUnmask` keeps the parent transfer masked while explicitly unmasking the supervisor; the retained lifecycle and live-metrics maps also share one STM registry cell. Quick probes returned hot-key throughput to baseline range and startup allocation from 6,645 to 5,196 bytes per cycle against a 5,004-byte baseline; the final paired rerun remains Milestone 4 evidence.

2026-09-20: The next paired run passed the corrected keyed and startup allocation paths but exposed a 15%--24% serial populated-inbox regression: checking the terminal `TVar` first made every successful receive join the STM read set. `ProcessorSignal` now pairs the terminal `TVar`, which wakes blocked intake, with a boolean `IORef` for the pre-existing fast check. A populated inbox again completes its receive branch without reading the terminal `TVar`; an empty inbox reads it through `orElse` and remains wakeable. Terminal publication masks the two writes so cancellation cannot leave only the fast flag set.

2026-09-20: Merely moving the terminal branch behind `receiveSTM` was insufficient: constructing a third `orElse` alternative added roughly 100--130 allocated bytes per message on the serial path. Splitting the empty check and wakeable wait into two transactions removed that allocation but made a frequently empty retry workload pay two transactions per message. The terminal signal now pairs an atomic outcome `IORef` with the existing source-completion wake cell: terminal publication records the exit before marking that cell. Intake therefore retains the original two-branch receive/completion transaction and the original populated and frequently-empty costs, while an idle terminal request still wakes the completion branch.


## Decision Log


2026-09-19: Treat infrastructure finalization failure as failure, not graceful Halt; preserve existing deliberate user halt and supported delivery semantics. This contract is final for planning purposes: the Kafka and PGMQ adapter plans begin before this plan completes and rely on it.

2026-09-19: Do not own the REV-16 supervisor-link findings here. The project owner judged them urgent and directed a standalone plan, docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, which ships as its own patch release. This plan only keeps that plan's two tests green and never restores a link on the supervisor thread.

2026-09-19: New constructors on the exported `ConfigError` and `PolicyError` types are a deliberate, recorded breaking change, not an accident to avoid. Rationale: duplicate processor IDs and nonpositive concurrency must be rejected with a structured error before any startup effect, neither type has a constructor that fits, and this initiative gates a major release. The retained terminal lifecycle snapshot, by contrast, stays in the unstable internal modules; a public worker-probe API is IR-1's separate design.

2026-09-19: Failure observability is defined per supervision strategy so that "reaches waitApp" is testable. Under `StopAllOnFailure` the failure reaches the thread that called `runApp` as the existing linked-thread exception and siblings are stopped. Under `IgnoreFailures` `waitApp` still returns normally, because its type has no failure channel and changing that belongs to IR-1; the failure must instead remain readable from the retained terminal snapshot with the failed processor's identity and the failed message identity.

2026-09-20: Add `totalShutdownTimeout` to `ShutdownConfig`, defaulting to 60 seconds while retaining the existing 30-second `drainTimeout`. It bounds adapter shutdown plus graceful drain and initiates forced master shutdown on expiry. As already accepted in REV-14-A1, no library timeout can bound user code that masks cancellation uninterruptibly. The first concurrent stop caller's configuration wins, every adapter is invoked once, and all callers observe its cached result. This public record-field addition is part of the planned major release and is recorded in ADR 0003 and both changelogs.

2026-09-20: The internal snapshot contract consumed by EP-39 is `type LifecycleSnapshot = Map ProcessorId ProcessorLifecycle`, where `ProcessorLifecycle = LifecycleRunning | LifecycleDraining | LifecycleStopped | LifecycleFailed Text (Maybe MessageId)`. Registration creates the bounded entry; live metrics unregister independently; deliberate halt and ordinary completion retain `LifecycleStopped`; infrastructure failure retains its rendered reason and message identity when available. No public probe is added.

2026-09-20: Export `ProcessorFailure Text (Maybe MessageId)` from the umbrella module so a `StopAllOnFailure` caller can distinguish an infrastructure finalization failure from `ProcessorHalt`. This is additive at the constructor level but deliberately changes the previously incorrect runtime outcome; it ships with the planned major release.


## Outcomes & Retrospective


Milestones 1 through 3 are implemented. The ordinary core suite now asserts deterministic cancellation at the startup ownership-transfer barrier; duplicate and policy rejection before acquisition; idle halt across Serial, Ahead, Async, partitioned and batch paths; traced and untraced finalizer failure; supervision-specific observability; exception-safe and bounded adapter shutdown; cancellation during drain; repeated/concurrent stop; prompt keyed failure with infinite input; and ticker failure. The implementation uses a wakeable STM terminal signal, separate graceful and infrastructure exceptions, masked ownership transfers, immediate keyed failure propagation, and coordinated shutdown. Milestone 4 remains open until candidate-bound evidence, the findings ledger, repeated schedule runs, and focused EP-45 performance comparison are complete.


## Context and Orientation


Primary modules are shibuya-core/src/Shibuya/App.hs, Internal/App.hs, Internal/Runner/Master.hs, Internal/Runner/Supervised.hs, Internal/Runner/BatchProcessor.hs, Internal/Runner/Ingester.hs, Internal/Runner/Halt.hs, Internal/Runner/Finalize.hs, Internal/Runner/KeyedScheduler.hs, Internal/Runner/Batcher.hs, Policy.hs and Core/Error.hs under the same Shibuya source root. Tests live in shibuya-core/test/Shibuya/App/LifecycleSpec.hs, RunnerSpec.hs, Runner/SupervisedSpec.hs, Runner/BatchProcessorSpec.hs, Runner/BatcherSpec.hs, Runner/PartitionOrderingSpec.hs, PolicySpec.hs, and Batch/ReliabilitySpec.hs, all under shibuya-core/test/Shibuya/. The reviews named below are checked in under docs/reviews/ and give line-level evidence; read the one for a finding before changing its code.

REV-3 documents cleanup short-circuiting, startup cancellation gaps, and duplicate processor IDs. In App.hs `stopAppGracefully` calls each adapter's `shutdown` with a plain `mapM_` and only afterwards calls `stopMaster`, so one throwing adapter skips every later adapter and the supervisor stop; `runApp` builds its handle with `Map.fromList`, which silently keeps only the last of two processors that share an ID although both were started; and the `try`/`catch` around startup come from UnliftIO, which deliberately does not catch asynchronous exceptions, so cancelling the caller during startup bypasses `stopMaster`. An asynchronous exception is one thrown into a thread from outside, such as cancellation, as opposed to a synchronous one raised by the code the thread is running.

REV-4 reproduces unwakeable halt and finalizer exhaustion reported as success. STM, software transactional memory, is GHC's mechanism for atomically reading and writing shared `TVar` variables; a blocked transaction is re-run only when one of the variables it read changes. In Supervised.hs `inboxToStream` reads the halt flag `haltRef`, a plain `IORef`, outside STM and then blocks in an STM transaction on the inbox and the `streamDoneVar` flag. Writing the `IORef` wakes neither, so a halt requested while intake is blocked is not seen until another message arrives. Separately, `processOne` turns exhausted finalizer retries into a `HaltFatal` reason in the same `haltRef`, and `runSupervised` catches every `ProcessorHalt` and exits normally; the batch path does the same in BatchProcessor.hs and `runSupervisedBatch`. `AckHalt` is the decision a handler returns to stop its processor deliberately; that case must stay graceful.

REV-5 records delayed keyed failure in KeyedScheduler.hs, including a start gate: a worker thread is created blocked on a gate and released only after it is registered, which leaves a short window where cancellation can strand an unregistered waiter. REV-6 reproduces zero/negative concurrency invoking Streamly defaults/unbounded concurrency, because `validatePolicy` in Policy.hs checks only the ordering/concurrency combination. REV-15 records batching residual risks, including a batch ticker whose exceptions are not monitored.

REV-16 is the newest review and is not in IR-6. It found that NQE's `Supervisor.supervisor`, which `startMaster` in Master.hs used, links the supervisor thread to the thread that called `runApp`; a link forwards a thread's failure to another thread as an `ExceptionInLinkedThread`. That link killed callers of finished applications during garbage collection and delivered every `StopAllOnFailure` failure twice. Both are fixed by the standalone plan docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, not by this one. That plan starts the supervisor unlinked, leaves failure delivery to the per-processor links Supervised.hs installs when `propagateFailures` is set, and adds the test suite `shibuya-core-gc-finished-test` plus a lifecycle case asserting a single delivery. Check that it is complete before changing Master.hs; if it is not, coordinate rather than editing `startMaster` from two plans. The decision record docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md covers this class of defect: never link a thread whose only wake source is reachable solely through a handle the caller may drop, never keep one alive with an artificial root, and test such liveness in a separate process that retains nothing but the action under test.

Core/Error.hs exports `ConfigError`, whose only constructor is `InvalidInboxSize`, and `PolicyError`, whose only constructor is `InvalidPolicyCombo`, both with all constructors visible.

The baseline is the committed source audit in docs/lifecycle-audit-progress.md and docs/reviews/, not a completed fault-injection campaign. Source inspection, diagnostic reproduction, fixed code, and release verification are separate evidence levels. A finalizer is the adapter operation that acknowledges, retries, or dead-letters a handled delivery. At-least-once delivery allows replay after interruption; it does not permit silently skipping unresolved work. A timeout in a test is a failure bound, not evidence that production cleanup succeeded.

When this plan was drafted no local docs/adr corpus existed; the repository's first record, docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md, was added on 2026-09-20 and is summarized above. The corpus is plain Markdown with no OKF profile, so keep that format. Before introducing durable interfaces, follow .agents/skills/exec-plan/ADR.md and record the decision using the then-current repository convention. Locate dependency sources with Mori before choosing APIs. Verify registry releases and upstream tags before changing dependency bounds. Registration-service-v2 is excluded.


## Plan of Work


Milestone 1 converts scripts/audit/LifecycleProbe.hs scenarios into assertions in existing Hspec suites. Add explicit barriers around acquisition/registration, empty inbox waits, finalizer retry exhaustion, and keyed worker failure with a still-live input stream. Add duplicate-ID tests for ordinary, batch and mixed processor entries, and invalid-policy tests. Run the finalizer-exhaustion and halt cases with tracing disabled as well as enabled, because IR-6 requires that failure stay observable when tracing is off. Observe failures on the audit baseline before fixes. For batch halt, exercise timeout-flush, size-flush, and partial final batches; check each acquired finalizer has one terminal invocation according to its retry contract.

Milestone 2 fixes lifetime ownership in App.hs, Internal/App.hs and Internal/Runner/Master.hs. Reject duplicate IDs and nonpositive `Ahead`/`Async` concurrency before launching any worker or acquiring adapter resources, returning new structured constructors on `ConfigError` and `PolicyError` respectively; record both as breaking changes in the changelogs. Overflow-checked capacity arithmetic is Milestone 4's work, not this milestone's. Use exception-safe acquisition with masking only around ownership transfer; restore interruptibility during blocking operations and handlers. Record each acquired resource before cancellation can lose it. Cleanup must attempt every adapter shutdown and stop the master even when an earlier shutdown fails, then surface the failure without replacing the original startup failure silently. Test synchronous and asynchronous exceptions at every transfer boundary, repeated stop, and concurrent wait/stop. Never use uninterruptible masking for arbitrary user or adapter I/O.

Milestone 2 also decides the shutdown deadline contract that REV-2, REV-3 and IR-6 item 3 leave open. Today `drainTimeout` starts only after every adapter `shutdown` action has returned, so one blocking adapter shutdown prevents force-stop indefinitely. Keep `drainTimeout` meaning what its documentation says, and add a separately named, separately documented total shutdown bound that also covers the adapter shutdown phase; when it expires the master is stopped regardless. Record the chosen default and its compatibility impact in the Decision Log, and test a never-returning adapter shutdown.

Milestone 3 makes stop and failure observable in Supervised.hs, Halt.hs, Finalize.hs and KeyedScheduler.hs. Replace the separate IORef-only halt observation around inbox waits with a stop signal that participates in the blocking STM decision, so halt wakes every strategy and batch mode. Keep deliberate user Halt distinct from exhausted/fatal infrastructure finalization failure; the latter must reach waitApp and the configured supervision policy. On first keyed worker failure, stop accepting input, wake blocked scheduler branches, terminate owned workers, and propagate the original failure without waiting for infinite upstream exhaustion. Close the spawn/register ownership gap, including workers waiting at a start gate. Preserve per-key ordering and documented graceful drain semantics. Test StopAllOnFailure and IgnoreFailures separately; ignoring a failed worker is not reporting that worker successful.

Milestone 4 validates positive Async/Ahead concurrency and checked arithmetic before calculating buffer sizes; reject values whose derived capacity overflows rather than silently wrapping or clamping. Retain serial semantics and existing accepted positive values. Re-audit ingester, batch consumer/ticker ownership, full queues, cancel during lease/finalizer operations, and timer failures; convert any reachable new defect into a failing regression and fix it within this ownership scope. Publish an internal terminal lifecycle snapshot (running, draining, stopped, failed with retained processor identity and, for finalization failure, the failed message identity) for metrics to consume without depending on the existence of a mutable metrics entry. Its home is Internal/Runner/Master.hs, next to the registry whose unregister-on-exit behavior currently erases failed processors; keep it bounded by the configured processor set rather than growing per event. Define concrete internal types after inspecting current APIs; do not add a public API accidentally. docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md is gated on this snapshot, so state its type and semantics in this plan's Interfaces section as soon as they are settled rather than at the end of the milestone. Run all core tests, GC suite, and schedule repetitions.

Before closing this plan, supply focused before/after performance evidence for its changed paths using docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md. Baseline capture is an early coordination requirement, not a reason to defer all measurement until release. Correctness and performance must both pass; the performance plan owns budgets and harnesses.


## Concrete Steps


Run local commands from the Shibuya repository root unless the command block explicitly directs a change to a Mori-resolved project. New validator and comparator commands become available when their owning milestones implement them. Use the repository development shell if the compiler or services are missing; an unavailable dependency in offline mode requires an approved fetch, not removal of the test.

```bash
cabal build lib:shibuya-core --offline
cabal test shibuya-core --offline --test-show-details=failures
cabal test shibuya-core:shibuya-core-gc-test --offline --test-show-details=direct
```

On the implementation tree, `cabal test shibuya-core --offline --test-show-details=failures` builds and passes the ordinary suite plus both isolated GC suites. The focused audit probe is compiled with its object directory outside the repository and now reports structured duplicate/policy rejection, successful idle halt for all strategies, both shutdown actions attempted after a synchronous failure, and prompt keyed failure. Exact candidate SHA, solver hash, repetitions, and logs are added to the EP-37 evidence artifact after the implementation commit exists.

Successful suites exit zero and report executed tests; zero tests or skipped services are not acceptance. Record exact selectors and fixture commands in this section when the harness is extended.


## Validation and Acceptance


Duplicate IDs and nonpositive/overflowing policies fail before startup with a structured error and zero acquired resources. Each acquired adapter is cleaned up once even if another throws, and a never-returning adapter shutdown is cut off by the total shutdown bound. Halt completes with empty/live sources in Serial, Async, Ahead, partitioned and batch paths. Exhausted finalization is a failure with tracing on or off: under StopAllOnFailure exactly one linked exception reaches the thread that called `runApp` and siblings stop; under IgnoreFailures `waitApp` returns and the terminal snapshot records the failed processor and message. Infinite upstream cannot suppress a keyed failure. No active worker or start-gate waiter survives cleanup. Existing ordering, retries, batch behavior, both process-isolated GC suites and the single-delivery lifecycle case still pass.

Use STM barriers or injected hooks to control interleavings; sleeps alone do not prove ordering. Assert terminal outcomes and resource ownership, not just logs. For every reproduced defect, record a failing regression against the affected implementation and a passing run against the fix; use an isolated worktree or mutation, never overwrite the working tree. Keep source-only suspicions labeled unconfirmed until reproduced or disproved. Record exact source SHAs, dependency solution, compiler, commands, random seeds, and logs in the EP-37 evidence format. Passing tests with a skipped service-dependent suite do not count as integration evidence.


## Idempotence and Recovery


Work on the current branch, preserve unrelated edits, and commit small conventional changes with MasterPlan, ExecPlan, and Intention trailers from this plan's frontmatter. Repeating unit tests and validation is safe. Use uniquely named ephemeral broker/database resources, never production endpoints or shared database reset commands. Bracket fixture cleanup and retain failed-run logs before deleting only identified fixture resources. Revert an identified implementation commit only with authorization; do not reset the checkout. Missing services or unavailable dependencies remain explicit blockers, not passes.


## Interfaces and Dependencies


Hard dependency: docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md for evidence acceptance. This plan alone owns App/Internal.App, Internal/Runner/Master.hs apart from the supervisor construction in `startMaster`, which belongs to the standalone plan docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, the terminal snapshot, supervision, stop/failure representation, policy validation, scheduler and batching lifecycle. docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md consumes the terminal snapshot and owns Core/Metrics.hs; this plan calls into that module from the runner but does not change its accounting model, and requests any new metrics hook at this boundary rather than having both plans change lifecycle semantics. The metrics plan's first milestone records the package's exact JSON and Prometheus output as golden fixtures under shibuya-metrics/test/golden/ and adds `cabal test shibuya-metrics` to the release gate. If a change in this plan alters what a metrics encoder emits, for example a new processor state, run that suite, update the affected fixture in the same commit, and record in both plans' Decision Logs that the wire change is deliberate; if the metrics suite does not exist yet, tell the metrics plan so its baseline is taken before this plan's change rather than after.

The settled internal consumer interface is:

```haskell
data ProcessorLifecycle
  = LifecycleRunning
  | LifecycleDraining
  | LifecycleStopped
  | LifecycleFailed Text (Maybe MessageId)

type LifecycleSnapshot = Map ProcessorId ProcessorLifecycle

getLifecycleSnapshot :: IOE :> es => Master -> Eff es LifecycleSnapshot
getLifecycleSnapshotIO :: Master -> IO LifecycleSnapshot
```

The map has at most one entry per configured processor ID and outlives the mutable metrics registration. EP-39 may read it but must not mutate lifecycle state or infer failure from a missing metrics handle.

This plan is a soft dependency of the metrics plan above and of docs/plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries.md, docs/plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults.md and docs/plans/43-make-kiroku-subscription-ownership-exception-safe.md. They start once the evidence plan is complete and do not wait for this one. Milestone 4's snapshot gates the metrics plan's lifecycle-aware health; Milestone 3's failure contract gates the Kafka and PGMQ plans' acceptance that a terminal acknowledgement failure is visible to the application. Because those plans are in flight concurrently, do not change the decided contract, that infrastructure finalization failure is failure and not Halt, without updating the parent MasterPlan first. Both this plan and the metrics plan append to the changelogs; add only this plan's entries under the unreleased heading, mark breaking ones, and do not choose the version. Source-only residuals must be tested or explicitly remain open.


## Revision Notes


2026-09-20 UTC: Revised after a pre-implementation review of the parent MasterPlan against docs/reviews, IR-6, the working tree and NQE 0.6.6. That review found the REV-16 supervisor-link defects; at the project owner's direction they are fixed by the standalone plan docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, so this plan only records the boundary with it and the obligation to keep its tests green. Added the modules and suites the drafted orientation omitted (Master.hs, BatchProcessor.hs, Ingester.hs, Core/Error.hs and three test files), since the batch half of the finalizer-exhaustion defect and the snapshot's home live there. Resolved three ambiguities the draft left to the implementer: the total shutdown deadline IR-6 asks for, how failure is observable under each supervision strategy, and that new error constructors are a deliberate breaking change. Separated nonpositive-concurrency rejection (Milestone 2) from overflow checks (Milestone 4), which the draft assigned to both. Recorded that this plan is now a soft rather than hard dependency of the metrics and adapter plans, noted the repository's new first ADR, and defined the terms of art the draft used without explanation.

2026-09-20 UTC: Added the obligation to keep the metrics plan's golden wire fixtures in step with any encoder-visible change made here, because that plan now characterizes the metrics package's published output before anything changes it and gates releases on it.
