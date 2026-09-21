---
id: 6
slug: comprehensive-lifecycle-remediation-and-release-assurance
title: "Comprehensive lifecycle remediation and release assurance"
kind: master-plan
created_at: 2026-09-20T04:04:59Z
intention: "intention_01m2yfmkqxeg9sc0wfmcp4w9fe"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-09-20T04:04:59Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:45:51Z
      verdict: "changes-requested"
      note: "Decomposition sound; EP-38 over-serialized four independent children, EP-45 would deadlock plan selection, adapters pin core 0.9, EP-39 fix left a false-unready path, Progress lacked the checklist; new REV-16 finding reproduced."
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:46:05Z
      mode: "update"
      note: "Cancel EP-42 (MessageDB deprecated); EP-38 becomes a soft dependency gating named acceptance; two-pass EP-45; adapter core-bound, Master.hs and changelog integration points; Progress checklist; REV-16 routed to standalone EP-46."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T14:01:52Z
      mode: "implement"
      note: "Started EP-37 evidence-gate implementation and coordination"
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T14:31:28Z
      mode: "implement"
      note: "Started EP-45 performance baseline, workload, and comparator implementation"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-20T19:10:00Z
      mode: "implement"
      note: "Completed EP-40 Kafka acknowledgement remediation and evidence; advance to EP-41."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-20T21:08:00Z
      mode: "implement"
      note: "Completed EP-41 PGMQ acknowledgement and durable dead-letter recovery remediation; advance to EP-43."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-20T21:45:00Z
      mode: "implement"
      note: "Completed EP-43 Kiroku ownership and checkpoint-recovery remediation; resume EP-45 pass two."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T00:37:40Z
      mode: "implement"
      note: "Refined supervised masking after EP-45 exposed unordered scheduler overhead; focused O2 candidate evidence passes."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T00:47:40Z
      mode: "implement"
      note: "Rejected per-message serial unmasking and selected one unmasked serial region from 40-pair O2 evidence."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-21T03:00:00Z
      mode: "implement"
      note: "Completed EP-45 pass two and started exact-candidate release-gate preparation for EP-44."
---

# Comprehensive lifecycle remediation and release assurance

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


Deliver a release candidate whose processor lifetime, acknowledgements, durable recovery, health reporting and performance are backed by reproducible evidence. Every historical finding receives an explicit disposition; every lifecycle boundary receives normal and fault-path coverage. The final output is a release verdict for exact source revisions and a dependency solution, not a guarantee that all possible bugs have been eliminated.

This initiative is the gate for the next major release of Shibuya. Deliberate breaking changes that a fix genuinely requires, such as new constructors on exported error types, are therefore in scope; each must be recorded for the changelog by the child that introduces it. Choosing the actual version number remains an execution-time release decision made from the accumulated diff, not from this planning document.

Include shibuya-core, shibuya-metrics and the adapters owned by mori://shinzui/shibuya-kafka-adapter, mori://shinzui/shibuya-pgmq-adapter and mori://shinzui/kiroku. The MessageDB adapter, mori://shinzui/shibuya-message-db-adapter, is deprecated and was excluded by the project owner on 2026-09-19: its REV-12 findings receive an explicit out-of-scope disposition in the evidence ledger rather than a fix, and the final verdict must name that adapter as uncertified and unsupported. Registration-service-v2 and unrelated consumer migrations are excluded. Production chaos, package publishing and deployment require separate authorization. General security certification and exactly-once external side effects are not promised.

The starting evidence is docs/lifecycle-audit-progress.md, docs/reviews/REV-1 through REV-16 as indexed by docs/reviews/index.md, and IR-6 in docs/improvement-requests/close-lifecycle-and-health-audit-gaps.md. REV-16 was added after the audit closed: it is an independent review of the master-loop removal that reproduces a residual garbage-collection failure and a duplicated failure delivery, described under Surprises & Discoveries. The project owner judged it urgent, so it is fixed by the standalone plan docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, outside this MasterPlan, which treats that plan as an external prerequisite. The audit includes source-only suspicions and targeted runtime reproductions, not comprehensive integration proof. The local source baseline observed during planning is d27448e, the 0.9.0.2 release commit; on 2026-09-20 UTC that commit was confirmed as upstream tag v0.9.0.2 and shibuya-core 0.9.0.2 was confirmed on Hackage. Historical review source SHAs remain authoritative for reproductions. Recheck HEAD and published state at execution time.

The GC-only repair and dependency/API compatibility work remain coordinated by docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md. Do not hold a separately approved emergency hotfix hostage to this broader initiative, and do not describe that hotfix as comprehensive audit clearance. Do not choose a future version number or new dependency pin merely from this planning document.


## Decomposition Strategy


Nine children were drafted; eight remain active after EP-42 was cancelled with the MessageDB adapter's exclusion. They are grouped into three phases. Phase A establishes a coverage/evidence contract (EP-37) and begins performance baseline capture (EP-45). Phase B fixes core ownership (EP-38), trustworthy observability (EP-39) and each in-scope adapter's distinct delivery/persistence contract (EP-40, EP-41, EP-43). Phase C completes performance comparison and integrated release certification (EP-44). Performance baseline work starts before hot-path remediation; its final comparison necessarily consumes the fixed candidate.

One large repair plan would hide ownership and leave integration assumptions implicit. A plan per source file would split failure paths that must be tested together. The selected streams instead have independently observable outcomes, and adapter fixtures stay with their owning repositories. Core ownership remains one cohesive child because startup, halt, finalization, supervision and scheduler cancellation share the same lifetime contract; it has four verifiable milestones.

No local docs/adr corpus existed during discovery. The repository's first record, docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md, was added on 2026-09-20 by the closing of the master-loop plan: remove a linked actor whose wait source has no remaining sender, never keep one alive with an artificial root, and test reachability-sensitive liveness in a separate process that retains only the action under test. The standalone REV-16 plan extends it to the supervisor thread; EP-38 and EP-44 must respect it. The corpus is plain Markdown with no OKF profile. The relevant cross-project decision read through Mori is mori://shinzui/kiroku/okf/adrs/concepts/ADR-4: explicit missing-checkpoint policy, preservation of existing checkpoints, monotonic normal saves, and a separate reset operation. The Kiroku child preserves it. Create local ADRs during implementation for terminal-state ownership, failure-versus-Halt semantics, durable DLQ idempotence, and release/performance evidence policy, following the repository's then-current ADR contract.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 37 | Establish lifecycle assurance coverage and evidence gates | [EP-37](../plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md) | None | None | Complete |
| 45 | Guard lifecycle fixes against throughput latency and memory regressions | [EP-45](../plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md) | EP-37 | EP-38, EP-39, EP-40, EP-41, EP-43 for final measurements; two-pass, see Dependency Graph | Complete |
| 38 | Make core processor ownership and termination exception safe | [EP-38](../plans/38-make-core-processor-ownership-and-termination-exception-safe.md) | EP-37 | Existing standalone EP-46 lands first in Master.hs; EP-45 baseline and focused measurements | Complete |
| 39 | Make metrics health and WebSocket lifecycle reporting trustworthy | [EP-39](../plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md) | EP-37 | EP-38 Milestone 4 snapshot gates lifecycle-aware health; EP-45 measurements | Complete |
| 40 | Prevent Kafka acknowledgements from skipping unresolved deliveries | [EP-40](../plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries.md) | EP-37 | EP-38 Milestone 3 failure contract gates terminal-acknowledgement acceptance; EP-45 measurements | Complete |
| 41 | Verify PGMQ acknowledgement and dead-letter recovery under faults | [EP-41](../plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults.md) | EP-37 | EP-38 Milestone 3 failure contract gates exhausted-finalization acceptance; EP-45 measurements | Complete |
| 42 | Repair MessageDB checkpoint and shutdown lifecycle semantics | [EP-42](../plans/42-repair-messagedb-checkpoint-and-shutdown-lifecycle-semantics.md) | None | None | Cancelled (MessageDB adapter deprecated; owner decision 2026-09-19) |
| 43 | Make Kiroku subscription ownership exception safe | [EP-43](../plans/43-make-kiroku-subscription-ownership-exception-safe.md) | EP-37 | EP-38 integration only, no gated milestone; EP-45 measurements | Complete |
| 44 | Certify the integrated lifecycle release candidate | [EP-44](../plans/44-certify-the-integrated-lifecycle-release-candidate.md) | EP-37, EP-38, EP-39, EP-40, EP-41, EP-43, EP-45; existing standalone EP-46; existing EP-34 and EP-35 compatibility gates | None | In Progress (matrix complete; human risk disposition and independent review pending) |

Existing EP-34, EP-35 and EP-46 are not children of this MasterPlan. EP-46 is docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, the urgent standalone fix for REV-16, which ships as its own patch release and is expected to complete before any child here starts. The exact paths and compatibility responsibilities of all three are recorded in EP-44; their completion must be checked rather than inferred from old status prose. EP-34 Milestones 1 through 3 and EP-35's complete source/test/combined-solve gates passed on 2026-09-21; their publication milestones await the same release-owner version coordination as EP-44. EP-46 is Complete: its fix was published as shibuya-core and shibuya-metrics 0.9.0.3 on 2026-09-20, which makes 0.9.0.3 the released baseline for this initiative and moves EP-34's provisional release to 0.9.0.4. Existing EP-36 concerns only the MessageDB adapter and is no longer a prerequisite of anything here.


## Dependency Graph


EP-37 defines the evidence schema consumed by every other child and is the only hard dependency inside Phases A and B: a remediation child cannot record an accepted red/green result without the ledger format and validator. EP-45 begins after it and captures a matched baseline before fixes are accepted.

EP-38 owns the core stop/failure and terminal lifecycle interfaces. It is a soft dependency of EP-39, EP-40, EP-41 and EP-43, not a hard one, because none of their code fails to compile or loses its meaning without it; holding four independent fix streams, two of which carry high-priority findings, behind all four core milestones would be an ordering preference rather than a real blocker. What EP-38 does gate is specific acceptance. EP-39's lifecycle-aware readiness and terminal WebSocket notifications need the retained terminal snapshot from EP-38 Milestone 4; its test suite, activity accounting and WebSocket slot ownership do not. EP-40's and EP-41's acceptance that an exhausted or terminal acknowledgement failure is visible to the application needs EP-38 Milestone 3, where finalization failure stops being reported as a graceful halt; the Kafka retry-barrier fix and the PGMQ idempotent dead-letter move do not. EP-43 has no gated milestone. A child may start once EP-37 is complete, but it may not be marked Complete until every acceptance it gates on EP-38 has been run against the completed core milestone. The semantic contract those children may assume in the meantime is already decided in EP-38's Decision Log: infrastructure finalization failure is failure, not Halt.

EP-45 is implemented in two passes, because its final verdict measures the fixed candidate while every remediation child needs its harness first. Pass one is Milestones 1 through 3: baseline, workloads and comparator. After pass one, set its registry status to In Progress with the note "paused after Milestone 3; resumes when EP-38, EP-39, EP-40, EP-41 and EP-43 are Complete". Whoever selects the next plan to implement must skip a paused EP-45 even though it is listed first and is In Progress. Pass two is Milestones 4 and 5 and starts only when those five children are Complete. Each remediation child in turn needs pass one finished before it can close, because it must supply focused before/after measurements from that harness. The resulting completion order is EP-37, then EP-45 pass one alongside the start of remediation, then the five remediation children, then EP-45 pass two, then EP-44. These mutual soft dependencies are an ordering of completion, not a cycle of blocked starts.

The standalone EP-46 changes only the supervisor construction in `startMaster`. EP-38 later adds the retained snapshot to the same module, so EP-46 is a soft dependency of EP-38: it should land first, and if it somehow has not, EP-38 coordinates rather than editing `startMaster` from two plans. EP-44 has hard dependencies on every active child, on EP-46 and on the applicable existing compatibility gates: it certifies their composition, not each child in isolation.

```text
Phase A: EP-37 --> EP-45 pass one (M1-M3) ------------------------+
Phase B: EP-37 --> EP-38 ......(M4 snapshot)......> EP-39          |
                   EP-38 ......(M3 failure contract)> EP-40, EP-41 |
         EP-37 --> EP-39, EP-40, EP-41, EP-43 --------------------+--> EP-45 pass two (M4-M5)
Phase C: all active children + EP-45 verdict + existing EP-46 + EP-34/35 gates --> EP-44
External: standalone EP-46 (urgent patch) ....> EP-38 (same module, lands first)

-->  hard dependency or completion order      ....>  soft dependency gating named acceptance only
```

A hard dependency blocks the start of a plan because it supplies a required artifact. A soft dependency permits the work to start and identifies an obligation that must be met before the dependent plan closes. No dependency edge authorizes writes to another repository; obtain the necessary workspace permission before implementation there.


## Integration Points


EP-37 owns docs/audits/lifecycle-release/findings.json schema, the coverage taxonomy, scripts/audit/validate-evidence.ts and evidence format. Each remediation child owns entries and artifacts for its assigned findings; EP-44 assembles the candidate manifest and final verdict. Preserve historical reviews and append new candidate review records rather than overwriting original evidence. The REV-12 MessageDB findings are owned by EP-37 only as ledger entries carrying the out-of-scope disposition and the owner's decision; no child fixes them.

EP-38 alone owns application lifecycle, stop/failure signaling, scheduler ownership and the retained internal terminal snapshot. That includes shibuya-core/src/Shibuya/Internal/Runner/Master.hs, because the registry's unregister-on-exit behavior is what makes failed processors vanish from health today, with one exception: how `startMaster` constructs the NQE supervisor belongs to the standalone EP-46, which starts it unlinked. EP-38 must keep EP-46's two tests passing, the process-isolated suite `shibuya-core-gc-finished-test` and the lifecycle case asserting a single failure delivery, and must never restore a link on the supervisor thread. EP-39 owns shibuya-core/src/Shibuya/Core/Metrics.hs and the metrics package, consuming that snapshot. EP-38 calls into Core/Metrics.hs from the runner but does not change its accounting model; if a core fix needs a new metrics hook, EP-38 requests it at this boundary and EP-39 defines it. Adapter children consume core's finalizer-failure contract and own their adapter delivery state. Neither metrics nor an adapter may quietly reinterpret failed finalization as successful Halt.

EP-40 owns Kafka unresolved-delivery/assignment tracking and broker fixtures. EP-41 owns PGMQ transactional DLQ behavior and database fault fixtures. EP-43 owns Kiroku subscription acquisition/transfer, preserving the accepted upstream checkpoint contract. Cross-project references use the project URIs above with explicitly project-relative paths where artifact-level source URIs remain pending.

Every in-scope adapter currently bounds shibuya-core to the 0.9 series: `^>=0.9.0.1` in the Kafka adapter, `^>=0.9.0.0` in the PGMQ adapter, and `>=0.9 && <0.10` in the Kiroku adapter. A candidate core carrying a new major version will not solve against them. During development each adapter child builds against the candidate core in a temporary Cabal project that relaxes only that one bound, and never commits the relaxation. The committed bound is changed once, by the adapter's own child, when EP-44 Milestone 1 fixes the candidate core version with the release owner; EP-44 verifies that the committed bounds admit the candidate, because final evidence must come from clean committed sources. Effectful bound policy stays with existing EP-35.

The metrics package has never had a test suite, and EP-39 owns creating it. Its first milestone characterizes the whole published contract, every HTTP route, every WebSocket frame and golden JSON and Prometheus output, before EP-39 or any other child changes what the endpoints report, so that a later wire change is either recorded as deliberate or caught. This adopts the test-suite item of IR-5, docs/improvement-requests/harden-shibuya-metrics-for-browser-clients-cors-tests-and-ws-convention-alignment.md; that request's cross-origin support and WebSocket convention alignment are new features and stay outside this initiative. EP-38 adds a retained lifecycle snapshot that Health will read, so any core change that alters a metrics encoder's output must update EP-39's golden fixtures in the same commit and record the decision there. EP-39 exports `combinedApp` from Shibuya.Metrics.Server for its harness, updates docs/capabilities/metrics-endpoints.md, and annotates IR-5 when its item is delivered.

The release skill, agents/skills/release/SKILL.md, is shared. Its step 4, the test gate, is edited by EP-39 to add `cabal test shibuya-metrics`, as the two garbage-collection fixes edited it for their suites; the repository has no continuous integration and `nix flake check` checks formatting only, so that step is the only place a suite runs routinely. Its step 5, the benchmark policy, remains existing EP-34's. `CLAUDE.md`'s command list follows step 4.

The root CHANGELOG and both package changelogs are touched by EP-38 and EP-39. Each child appends only entries for its own changes under the unreleased heading and marks any breaking change as such; neither rewrites the other's entries, and neither chooses the version.

EP-45 owns benchmark scenarios, comparator and performance-budgets.json. It uses fixtures supplied by EP-40, EP-41 and EP-43 and produces a candidate-bound verdict consumed by EP-44. Existing EP-34 owns release-skill dependency benchmark policy; coordinate changes there rather than editing that shared policy from two plans. Each remediation child supplies focused performance evidence before closure; the final matrix is mandatory regardless of patch/minor version.

Release acceptance requires every mandatory matrix cell to run, confirmed defects to have red/green tests, source-only concerns to be reproduced or disproved, durable restart behavior to be observed on real ephemeral services, and no stale evidence after source/dependency changes. Proposed starting performance limits are 5% throughput loss, 10% tail/shutdown latency increase, and 5% allocation/live-memory increase, with paired-run confidence bounds and separately calibrated absolute idle budgets. Inconclusive measurements do not pass. Existing stricter budgets win. Changing a failed budget or accepting a residual risk requires a named human release-owner decision, never an automatic agent waiver. No data-loss, hang, orphan-worker, or sustained-memory-growth finding can be hidden by aggregate throughput improvement.

Status is visible in this registry and each child's Progress. During implementation, record timestamped milestone evidence and blockers at every stopping point; never use “audit complete” to mean merely “source read.” The final verdict names exact candidate SHAs, test counts, unexecuted cells, performance results, residual risks, and independent review.


## Progress


EP-37 is complete: it established the review inventory, lifecycle boundary taxonomy,
validators, candidate layout, and execution budgets. Check any later item only when the
owning child records its acceptance evidence. The standalone EP-46 tracks its own progress
and is verified, not tracked, here.

- [x] EP-37 M1: Inventory every finding and lifecycle boundary, including REV-16 and the out-of-scope REV-12 dispositions.
- [x] EP-37 M2: Implement and test the evidence validator.
- [x] EP-37 M3: Document candidate manifests and execution budgets.
- [x] EP-45 M1: Capture matched baseline data before remediation.
- [x] EP-45 M2: Extend production-runner and lifecycle performance workloads.
- [x] EP-45 M3: Implement and test the statistical performance comparator. EP-45 pauses here.
- [x] EP-38 M1: Add deterministic regressions for ownership, halt, failures and policies.
- [x] EP-38 M2: Fix exception-safe resource acquisition and cleanup, and decide the total shutdown bound.
- [x] EP-38 M3: Make stop/failure wakeups and scheduler ownership reliable.
- [x] EP-38 M4: Validate capacities, publish the terminal snapshot and verify all core/GC regressions.
- [x] EP-39 M1: Characterize the published HTTP and WebSocket contract in a new metrics test suite, before any behavior changes, and add it to the release gate.
- [x] EP-39 M2: Repair activity accounting and lifecycle-aware health.
- [x] EP-39 M3: Fix WebSocket ownership, enablement and subscriptions.
- [x] EP-39 M4: Verify endpoint compatibility and accounting together, and retire the metrics package's "unproven" caveat.
- [x] EP-40 M1: Reproduce Kafka acknowledgement interleavings with a reference model.
- [x] EP-40 M2: Fix unresolved-delivery tracking and terminal failure propagation.
- [x] EP-40 M3: Verify recovery and reassignment against a live ephemeral broker.
- [x] EP-41 M1: Reproduce ambiguous commits and finalizer fault paths.
- [x] EP-41 M2: Implement durable idempotent DLQ movement.
- [x] EP-41 M3: Verify leases, outage recovery and restart on ephemeral PostgreSQL.
- [x] EP-43 M1: Reproduce member acquisition and cleanup ownership gaps.
- [x] EP-43 M2: Implement exception-safe group ownership transfer.
- [x] EP-43 M3: Verify acknowledgement and checkpoint recovery with the real store.
- [x] EP-45 M4: Measure fixed adapters and candidate soaks.
- [x] EP-45 M5: Publish raw data and the candidate-bound performance verdict.
- [x] EP-44 M1: Freeze an exact compatible candidate manifest, including the core version and adapter bounds.
- [x] EP-44 M2: Execute the full fault, restart and soak matrix.
- [ ] EP-44 M3: Verify performance evidence and obtain independent review.
- [ ] EP-44 M4: Validate and publish the release-readiness verdict without releasing packages.

EP-42 is cancelled and contributes no milestones.


## Surprises & Discoveries


**The master-loop removal left a second thread of the same kind (2026-09-20 UTC, plan review).** Reviewing the EP-33 fix against NQE 0.6.6 showed that `Supervisor.supervisor` is itself a mailbox process linked to the thread that called `runApp`, and that with zero children it waits only on that mailbox. Once every processor has finished, halted or failed and the caller drops the handle without `stopApp`, the next major collection kills the still-running caller. `scripts/audit/ChildlessSupervisorProbe.hs` reproduces it three runs out of three under both supervision strategies, while calling `stopApp` or retaining the handle survives:

```text
RESULT drop/ignore: CALLER KILLED: ExceptionInLinkedThread (ThreadId 6) thread blocked indefinitely in an STM transaction
RESULT stop/ignore: caller survived
RESULT retain/ignore: caller survived
```

The EP-33 regression did not catch it because its one idle child keeps the supervisor reachable. The same link also delivers every `StopAllOnFailure` failure to the caller twice, once from the processor's own link and once from the supervisor's; `scripts/audit/LinkedFailureDeliveryProbe.hs` counts two deliveries, and in two of three runs the second one landed outside any handler and ended the process. Both findings are recorded as docs/reviews/REV-16-childless-supervisor-gc-residual.md. A prototype that starts the supervisor unlinked fixed the first in 18 of 18 probe runs with both existing core suites passing. The project owner called this urgent, so it is handled by the standalone plan docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, not by a child of this MasterPlan. It affects EP-37's inventory range, EP-38's boundary in Master.hs and EP-44's forced-GC matrix cell.

**The drafted activity-accounting fix would have kept a false-unready path open.** shibuya-metrics/src/Shibuya/Metrics/Health.hs calls a processor stuck when it is in the Processing state and the burst start is older than the threshold. EP-39 originally prescribed only resetting the burst start on a zero-to-one in-flight transition. Under sustained load with concurrency above one, in-flight work never returns to zero, so a healthy busy worker would still be reported stuck after the 60-second default. REV-7 and IR-6 item 8 both warn about exactly this. EP-39 now bases stuck detection on absence of progress and requires a sustained-throughput test.

**Adapters pin core to 0.9.** The three in-scope adapters will not solve against a major-version candidate core. This is now an integration point with a single owner per bound and a verification step in EP-44 Milestone 1.

**The evidence ledger has 52 records rather than one row per headline defect (2026-09-20
UTC, EP-37 Milestone 1).** Preserving every review's findings, source concerns, limitations,
assumptions, and positive verification keeps source evidence distinct from later runtime
confirmation and prevents narrow approvals from erasing untested states. Downstream children
must update every applicable review-derived key they close, even when one regression or fix
satisfies several entries. The 15 lifecycle boundaries contribute 70 mandatory in-scope
matrix cells plus five explicit MessageDB exclusions.

**Evidence belongs to a complete candidate identity, not an individual test (2026-09-20 UTC,
EP-37 Milestones 2-3).** A passing run records the full source-SHA map and unified solver-plan
hash. Changing any source or dependency solution invalidates every result from that run, even
if a particular test lives in an unchanged package. Finding results and matrix cells reference
the run rather than copying a partial identity. Downstream children must preserve that
indirection when they append evidence.

**The unmodified idle worker exceeds the guessed 2% CPU cap (2026-09-20 UTC, EP-45 pass
one).** Ten fresh-process samples under N1 and N4 measured 2.256% to 3.712% CPU and 53,184 to
87,552 live bytes. Before any candidate observation, EP-45 calibrated the absolute caps to 4%
CPU and 131,072 live bytes, preserving the 1-point and 32,768-byte adverse-delta checks. The
320 raw calibration samples lost no acknowledgements. They deliberately cannot serve as final
paired evidence; pass two rebuilds this exact baseline and alternates it with the candidate.

**Lifecycle observation and masking can become hot-path costs (2026-09-20 UTC, EP-38).**
Focused paired measurements found four implementation-level regressions before acceptance: a
recursive exception-restore frame chain in the keyed scheduler, masked supervisor and processor
children, terminal STM reads/branches on populated inboxes, and an Effectful exception observer
around the whole processor computation. Narrowing masked ownership transfers, restoring child
interruptibility, keeping terminal outcome reads off the populated-inbox transaction, and
classifying failure once at the unlifted IO boundary preserved the new lifecycle contract while
returning every N1/N4 cell inside the original budgets. The retained diagnostic comparisons are
part of EP-38's evidence rather than being discarded after the fixes.

**A healthy endpoint must normalize provider failures without swallowing control exceptions
(2026-09-20 UTC, EP-39).** Endpoint-level testing found that synchronous dependency exceptions
escaped the WAI application instead of producing 503. Catching only exceptions outside
`SomeAsyncException` fixes the published health contract while preserving both cancellation and
`System.Timeout`. The same closeout confirmed that the only deliberate golden change is additive
`lastProgress`; Prometheus remains byte-for-byte compatible.

**Kafka recovery needs delivery identity as well as an offset (2026-09-20 UTC, EP-40).** The
reviewed barrier stored only one offset, so a later buffered retry overwrote the earliest
obligation and the original callback was indistinguishable from its replay. Delivery tokens
plus assignment generations make both distinctions explicit. The unchanged baseline fails the
two promoted regressions; the candidate passes deterministic seeds, live buffered retry/restart,
and an actual two-consumer reassignment. Exhausted acknowledgement errors also require a typed
synchronous exception: the Kafka `Error` effect sits outside core's finalizer boundary and
cannot by itself produce the retained `LifecycleFailed` result after ingestion ends.

**The Kafka adapter's Nix default package was already unevaluable as a build (2026-09-20 UTC,
EP-40; closed 2026-09-21 UTC, EP-44).** `nix flake check` reached a generated
`callCabal2nix` invocation at the repository root, where no Cabal file exists; the real package
is one directory below. EP-44 corrected that path and pinned the authoritative released Kafka,
Shibuya, Streamly, and OpenTelemetry compatibility set in
`mori://shinzui/shibuya-kafka-adapter` commit `35a3e41`. The repaired output passes
`nix build .#default` and `nix flake check`; candidate-only tests remain a separate passing
cross-repository Cabal gate until the new core is published.

**PGMQ dead-letter idempotence can use the source row as the durable claim (2026-09-20 UTC,
EP-41).** The dependency's delete statement already returns whether it removed the source row.
Deleting first and conditionally sending in the same transaction avoids a new schema or
deduplication table: rollback restores the row on send failure, and retry after a lost commit
response observes that the row is absent. A per-handle exception-safe lock still matters for
concurrent and cancelled callbacks, but it is deliberately not the crash-safety boundary.

**Adapter-local error effects do not cross core's finalizer observer (2026-09-20 UTC,
EP-41).** As in Kafka, an exhausted acknowledgement must become a typed synchronous exception
after the adapter failure hook runs. The candidate proves that ordinary and automatic DLQ
failure preserve the source and produce EP-38's retained `LifecycleFailed` outcome after the
source has ended.

**Performance evidence must amortize process startup and compiler closure shape (2026-09-20
UTC, EP-45 pass two).** The first final-capture attempt used zero-delay workloads too short to
stabilize allocation and live-heap ratios. A symmetric workload-version increase made an
optimized ticky profile actionable: terminal signal/wake/envelope retention added 72 bytes per
message, and EP-39's burst atomic plus CAS decrement added another 32 bytes and about 9-10%
serial time. Opaque boxed cold-path publication and sampler-side transition detection recover
the original hot path while retaining the idle-intake wake and health regressions. Version-1
pass-two artifacts are rejected, not reinterpreted.

**A post-drain cancellation is not a graceful-shutdown benchmark (2026-09-20 UTC, EP-45 pass
two).** The first full version-2 N1 matrix timed one `stopMaster` only after each processor had
finished, yielding 8-90 microsecond values and a misleading relative failure. Version 3 retains
the raw observation but gates shutdown only through repeated cold startup/stop and a new public
`runApp`/`stopAppGracefully` scenario with 1,000 messages and bounded backlog. The 10% budget is
unchanged, all work must still acknowledge, and the comparator now rejects a mutually omitted
mandatory scenario.

**Restoring an entire NQE child can penalize Streamly's unordered scheduler (2026-09-20 UTC,
EP-45 pass two).** The first complete version-3 N1 capture found the same 6.2% allocation and
7-8% throughput regression in all four `Async 4`/`Unordered` scenarios. A history bisect and
optimized ticky profiles traced it to whole-child unmasking: NQE 0.6.6 registers the child under
a mask, while restoring the entire computation makes Streamly install per-item exception
bookkeeping. Keeping framework coordination `MaskedInterruptible` and unmasking only the owned
adapter source and individual message/batch action preserves handler/finalizer cancellation and
the lifecycle ownership guarantees. Forty alternating O2 N1 pairs pass all 20 affected cells;
the tightest throughput upper bound is 1.04655 against the unchanged 1.05 limit.

**Unmasking per item is itself a serial hot-path cost (2026-09-21 UTC, EP-45 pass two).** The
first complete recapture against `c25a9188` passed the repaired unordered paths but rejected both
serial burst scenarios: throughput was 9.7% and 11.7% worse, with confidence intervals wholly
beyond the 5% gate. Serial processing has no concurrent scheduler to protect, so unmasking its
region once removes the per-message transition while Ahead, Async, and partitioned schedulers
retain scoped action unmasking. Forty fresh O2 N1 pairs pass all ten serial cells; the adverse
throughput upper bounds are 0.98674 and 1.02400.


## Decision Log


2026-09-19: Separate evidence, core lifecycle, observability, adapter remediation, performance and certification. This makes ownership and independently verifiable outcomes explicit without treating the existing passing suite as comprehensive assurance.

2026-09-19: Preserve the existing hotfix/compatibility master and its responsibilities. The new initiative closes the broader audit and adds missing tests; it does not duplicate releases or claim publication from local version metadata.

2026-09-19: The user explicitly requested performance-regression prevention. Add EP-45 and make its final verdict a hard release gate, with early baseline capture, realistic backpressure, tail latency, allocation, memory, idle CPU and live-adapter coverage.

2026-09-19: Use intention intention_01m2yfmkqxeg9sc0wfmcp4w9fe, created through mina ci as requested, for this master and every child. Plan creation does not authorize implementation, release or cross-workspace writes beyond the requested scope.

2026-09-19: Cancel EP-42 and exclude the MessageDB adapter. The project owner stated during plan review that the adapter is deprecated and that the adapters that matter are Kafka, PGMQ and Kiroku, with Kiroku called critical. Fixing a deprecated adapter would spend the initiative's budget on code that will not ship, and its prerequisite EP-36 migration was not started. The REV-12 findings are not deleted or marked resolved: they keep an out-of-scope disposition citing this decision, and EP-44's verdict lists the adapter as uncertified. EP-36 is removed as a prerequisite of this initiative.

2026-09-19: Downgrade EP-38 from a hard to a soft dependency of EP-39, EP-40, EP-41 and EP-43, gating named acceptance instead of the start of work. Rationale: the MasterPlan specification reserves hard dependencies for cases where the dependent plan would not compile or make sense; here only the terminal snapshot and the finalizer-failure contract are real artifacts, and each gates a specific acceptance rather than a whole plan. Serializing would have held the Kafka offset-skipping fix and the false-unready health fix, both high priority, behind four unrelated core milestones. The risk of rework is bounded because the contract those children assume is already decided in EP-38's Decision Log.

2026-09-19: Keep EP-45 as one plan but run it in two explicit passes with a paused registry status. Rationale: as drafted, EP-45 was listed before the children it must measure and could not complete until they did, so the implement protocol, which picks the first plan whose hard dependencies are complete and whose status is Not Started or In Progress, would select it forever. Splitting it into two plans was the alternative; the pause note achieves the same ordering without cancelling and recreating a drafted child.

2026-09-19: Keep the REV-16 fix outside this MasterPlan. The project owner judged the defect urgent and directed that it be handled independently, as docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, which has no dependency on EP-37 and ships as its own patch release in the manner of the 0.9.0.2 fix. Folding it into EP-38 would have queued a small, already-prototyped change to one function behind the evidence ledger and the largest child. This MasterPlan therefore treats EP-46 as an external prerequisite: EP-37 inventories its findings with that plan as owner, EP-38 respects its boundary in Master.hs, and EP-44 verifies its completion.

2026-09-20: Widen EP-39 so that the initiative actually closes the metrics package's missing test suite, instead of adding a new child. As drafted, EP-39 built a suite only to reproduce three audited defects; the routes, frames and encoders stayed unproven, Milestone 4's rule against incidental schema changes had no baseline to enforce it, and no routine gate would ever run the suite again after certification. The work belongs in EP-39 because it must come before EP-39's own wire changes and shares their harness; a separate child would have needed EP-39's fixtures and added a dependency edge for no independent outcome. Of IR-5's three items only the test suite is adopted, because it needs no new feature; cross-origin support and convention alignment serve a browser client and are not release safety. Defect tests are committed with their fixes rather than red, because the suite joins the release gate and the project has shipped two urgent patches in two days that a red gate would have blocked.

2026-09-19: Treat the next release as a major one for planning purposes. Rejecting duplicate processor IDs and nonpositive concurrency with structured errors requires new constructors on exported error types, which is a breaking change under the Haskell Package Versioning Policy. Children may make such changes deliberately and must record them; they still do not pick the version.

2026-09-20: Adopt EP-37's candidate-bound evidence-run identity and the durable policy in
`docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`. The complete
source-SHA map and solver-plan hash are the unit of freshness; a changed input creates a new
candidate and reruns affected evidence rather than editing old artifacts. This makes stale
evidence rejection consistent across all five remediation streams and final certification.

2026-09-20: Accept EP-40's Kafka acknowledgement state machine at adapter implementation SHA
`554c969b1d95842628d0483f7ae6331c87249a84`. The earliest unresolved delivery remains the
barrier until a newer replay succeeds; installed rebalance callbacks fence old assignment
generations; terminal ack exhaustion is a processor failure. Serial processing and the absence
of a DLQ producer remain explicit adapter limits. The focused live AckRetry comparison passes,
while EP-45 retains ownership of the final adapter matrix and soak.

2026-09-20: Accept EP-41's PGMQ delete-first transactional claim at adapter implementation SHA
`130b2502a9eaaa2d6f7f927baf9235510297a9f8`. A DLQ send occurs only when deletion claims the
source row; rollback keeps failed moves recoverable and retry after ambiguous commit emits no
second copy. Exception-safe per-handle ownership and typed terminal failure cover concurrency,
cancellation, and core lifecycle visibility. At-least-once delivery and lease-expiry replay
remain explicit; exactly-once application side effects are not claimed.

2026-09-20: Accept EP-43's masked acquisition ledger and store-bridge handoff at Kiroku
implementation SHA `eb67688690d5e96427cb8ff6cbf1488b81c279cf`. Cleanup attempts every
acquired member without replacing the primary failure, and deterministic cancellation cannot
strand a returned subscription. The real-store matrix preserves ADR-4's at-least-once replay,
existing-checkpoint, and missing-checkpoint semantics; exactly-once side effects are not claimed.

2026-09-20: Accept EP-45's 0.9.0.3 N1/N4 capture as pre-remediation calibration and pause the
plan after Milestone 3. The capture fixes the absolute idle budgets before candidate observation
but is marked ineligible for final paired comparison, because a candidate did not yet exist to
alternate with it. Each remediation child can now use the committed harness for focused
before/after evidence; EP-45 pass two rebuilds the same baseline for the final paired verdict.

2026-09-20: Accept EP-45 workload version 2 and the profiling-driven internal remediation as
candidate-selection work, not final evidence or a budget revision. Baseline and candidate run
the identical revised workload; the existing 5%/10% budgets and minimum ten alternating pairs
remain unchanged. Correctness takes precedence over a faster unsafe variant: every supervised
strategy retains terminal publication plus an STM wake for idle intake.

2026-09-20: Accept EP-45 workload version 3 as a measurement-correctness refinement. Applying a
relative shutdown budget to one post-drain cancellation did not test the intended contract and
produced confident percentage changes from three-microsecond absolute differences. Final
evidence instead applies the same 10% limit to repeated startup/stop and graceful drain under a
live bounded backlog; no threshold, confidence level, or minimum pair count changed.

2026-09-20: Accept scoped action unmasking for the EP-45 candidate. Registration, linking,
publication, scheduler coordination, and cleanup remain masked; only owned adapter source and
message/batch actions use `unsafeUnmask`. This is the narrowest boundary that keeps the existing
handler interruptibility and cancellation regressions green without imposing Streamly's
whole-scheduler cost. No performance budget changed. The four near-boundary N1 scenarios use 40
pairs because 20 pairs left two throughput intervals inconclusive.

2026-09-21: Refine scoped action unmasking by concurrency shape. Serial message and batch
processing regions are unmasked once; concurrent schedulers remain masked and unmask each owned
action. The distinction preserves handler/finalizer interruptibility without paying either
Streamly's unmasked concurrent bookkeeping or a serial per-message masking transition. The
original budgets remain unchanged.

2026-09-21: Accept EP-45's candidate-bound performance result. Both complete N1/N4 core
verdicts pass 84 cells, all nine live-adapter runs pass, and the real-wire stress fixtures lose
no work or WebSocket slots. REV-15-L1's finite high-cardinality envelope is measured but the
underlying unbounded-key limitation is not waived; EP-44 must obtain the explicit human release
disposition before certification.


## Outcomes & Retrospective


EP-37 completed the coordination foundation: 52 review-derived records, 15 lifecycle
boundaries, 70 mandatory in-scope cells, a 17-test validator, and an append-only candidate/run
layout with fixed execution budgets. Its intentionally incomplete candidate fails with 152
actionable errors and surfaces all five MessageDB exclusions. No open remediation finding is
closed by this result; the ledger now makes those gaps mechanically visible to every later
child and to final certification.

EP-38 completed core lifecycle remediation at implementation SHA
`2108292e15c2cf79e40e8ca09a74604926beaedc`. It closes its 13 fixable review-derived entries,
retains the one accepted runtime limitation, and passes all 45 owned lifecycle-boundary cells.
The evidence includes a red/green lifecycle probe, 236 ordinary examples, both isolated GC
suites, eight schedule-sensitive tests at 100/100 seeds, and focused paired performance under
N1 and N4 with no waiver or budget change. Its retained bounded lifecycle snapshot now unblocks
EP-39's lifecycle-aware health work, and its infrastructure-failure contract unblocks EP-40 and
EP-41 acceptance.

EP-39 completed observability remediation at implementation SHA
`6535a036827c0bdfa1dd8c8a3ca9d228776f3f51`. It closes all nine fixable REV-7 through REV-9
entries and passes all ten metrics/health and WebSocket boundary cells. Its new 48-example
release-gated suite covers every published route, exact JSON and Prometheus output, every frame,
and real sockets; final verification also passed 236 core examples and both GC suites. Focused
activity and socket comparisons stayed inside the inherited 5% budget without a waiver. The
remaining IR-5 CORS/Origin and broader convention work stays explicitly outside this initiative.

EP-40 completed Kafka persistence remediation at implementation SHA
`554c969b1d95842628d0483f7ae6331c87249a84`. It closes the two confirmed defects, validates
the documented assumptions, and passes all five Kafka persistence cells with 53 deterministic
and live-broker tests. Its focused live AckRetry latency interval remains inside the 10% budget.
The pre-existing broken Nix default-package output stays visible for EP-44 rather than being
treated as an acknowledgement failure or a pass.

EP-41 completed PGMQ persistence remediation at implementation SHA
`130b2502a9eaaa2d6f7f927baf9235510297a9f8` and final evidence SHA
`fe26ce9064999f6b4e373a6a283139c6f68a5971`. It closes the ambiguous-commit, concurrency,
and automatic-failure entries, runtime-verifies lease-expiry replay, and passes all five PGMQ
persistence cells with 177 examples against ephemeral PostgreSQL. The focused live AckOk
latency interval is +0.039% to +4.214%, inside the inherited 10% budget.

EP-43 completed Kiroku ownership remediation at implementation SHA
`eb67688690d5e96427cb8ff6cbf1488b81c279cf`. It closes the acquisition/cleanup defect and
the real-store and documentation limitations, runtime-verifies the accepted replay assumption,
and passes all five Kiroku persistence cells with 38 adapter and 308 store examples against
ephemeral PostgreSQL. The focused shutdown latency interval is -3.373% to +4.294%, inside the
inherited 10% budget. All Phase B remediation children are complete, so EP-45 pass two resumes.

EP-45 completed pass two at candidate production SHA
`6461c74cda5235e292d221f36621d09910b3b6f0`. Its full paired N1 and N4 core matrices pass all
168 measured cells, and Kafka, PGMQ, and Kiroku pass sustainable, saturation, and 30-minute
midpoint-restart captures with exact terminal counts, zero failures, zero final backlog, and
bounded retained heaps. Real-wire stress adds 100,000 successful readiness requests and 10,000
successful WebSocket cycles. A 50-process diagnostic quantifies REV-15-L1 through 50,000 distinct
batch keys without pretending the implementation now bounds that key count. EP-44 is active;
the candidate version, this residual limitation's human disposition, and independent review
remain explicit certification prerequisites.

EP-44 release-gate preparation repaired Kafka's default Nix package in
`mori://shinzui/shibuya-kafka-adapter` commit `35a3e41` and raised its acknowledgement model
budget to 1,000 deterministic seeds in commit `d2725ba`. The adapter passes its full
candidate-core suite against live Kafka, and the portable released-dependency flake passes both
its default build and flake checks. Candidate freeze remains blocked on the release-owner
version and residual-risk decisions; independent review also remains outstanding.


## Revision Notes


2026-09-20 UTC: Reviewed the MasterPlan and all children against docs/reviews, IR-6, the working tree, the three in-scope adapter repositories and NQE 0.6.6, at the project owner's request before implementation. Changes: cancelled EP-42 and removed the MessageDB adapter and EP-36 from scope on the owner's instruction; recorded the newly reproduced REV-16 findings and, because the owner judged them urgent, registered their standalone fix plan EP-46 as an external prerequisite rather than a child; noted the repository's new first ADR; corrected the dependency model so EP-38 gates named acceptance instead of blocking four independent children; defined the two-pass protocol that stops EP-45 from deadlocking plan selection; added integration points for Master.hs ownership, adapter core bounds and changelogs; replaced the prose Progress placeholder with the milestone checklist the specification requires; and corrected EP-39's activity-accounting prescription. The reason throughout is that the plans must actually close the audited defects before a major release, and several drafted details would have left a defect open or the initiative unable to proceed.

2026-09-20 UTC: Recorded that the external prerequisite EP-46 is complete and released as 0.9.0.3. No child, dependency or scope changed; EP-45's baseline capture and EP-44's candidate manifest should now treat 0.9.0.3, not 0.9.0.2, as the latest released source.

2026-09-20 UTC: Widened EP-39 at the project owner's request so that the initiative closes the metrics package's missing test suite: its first milestone now characterizes the full published contract before any behavior changes, adopting the test-suite item of IR-5, and the suite joins the release gate. Added the integration points this creates, golden fixtures shared with any core change that alters an encoder and the release skill's test step shared with the garbage-collection fixes, and recorded the decision. No child, dependency edge or scope boundary otherwise changed.

2026-09-20 UTC: Completed EP-37. Added the complete review and lifecycle-boundary inventory,
tested inventory and release validators, the append-only candidate evidence layout, execution
and initial regression budgets, and ADR 0002. The registry and aggregate progress now mark all
three EP-37 milestones complete; later children consume its schema and candidate-run identity.

2026-09-20 UTC: Completed EP-45 pass one and paused it after Milestone 3. Added the shared
lifecycle load catalog, one-process JSON sampler, deterministic comparator, precommitted and
calibrated budgets, and 320 N1/N4 samples against the released 0.9.0.3 production code. The raw
capture is explicitly calibration-only; final paired evidence remains EP-45 pass two after all
five remediation children complete.

2026-09-20 UTC: Completed EP-38. Added exception-safe startup, child ownership and coordinated
shutdown; explicit configuration/capacity validation; wakeable halt and failure outcomes;
prompt keyed/ticker failure propagation; distinct infrastructure finalization failure; and a
bounded retained lifecycle snapshot. Updated all EP-38 findings and 45 boundary cells with
candidate-bound raw evidence. The final focused performance union passes N1 and N4 using the
original EP-45 budgets, so no release-owner waiver or post-observation budget change was used.

2026-09-20 UTC: Started EP-39 as the next eligible child. EP-45 remains paused by its explicit
two-pass protocol. EP-38's completed snapshot removes both of EP-39's soft-gated waits, so the
child can implement characterization, activity/health, WebSocket ownership, and final endpoint
verification in sequence.

2026-09-20 UTC: Completed EP-39. Added the full release-gated metrics contract suite,
progress-based and lifecycle-aware health, bounded dependency checks with synchronous exception
normalization, exception-safe WebSocket ownership, explicit enablement/subscriptions, graceful
shutdown, and bounded terminal frames. Closed nine findings and ten boundary cells with
candidate-bound logs, preserved the 5% focused performance budget, and updated CAP-10 and IR-5
without expanding scope into CORS or broader protocol convention work. EP-40 is now the next
eligible unstarted child while EP-45 remains paused.

2026-09-20 UTC: Started EP-40 at the unchanged reviewed Kafka adapter baseline. Its core soft
gate is already satisfied by EP-38, and EP-45 remains paused until all remediation children are
complete.

2026-09-20 UTC: Completed EP-40 and EP-41. Kafka now preserves the earliest unresolved
delivery and fences assignment generations with live-broker evidence. PGMQ now claims the
source row before conditional DLQ send and surfaces terminal finalizer failure with ephemeral
PostgreSQL red/green, restart, cancellation, repeated-stop, and performance evidence. Their
ledger entries and all ten adapter persistence cells are closed. EP-43 is the next eligible
child; EP-45 remains paused by its two-pass protocol.

2026-09-20 UTC: Started EP-43 at the unchanged reviewed Kiroku baseline. Resolved the owner,
accepted checkpoint ADR, and Effectful masking source through Mori; confirmed the 32-example
released-baseline suite; and isolated the work from an incompatible ignored local Cabal
override. EP-45 remains paused until this final Phase B child completes.

2026-09-20 UTC: Completed EP-43. Kiroku now owns each returned subscription before
cancellation can interrupt construction, attempts all LIFO cleanup while preserving the primary
error, and closes the store bridge's subscribe-to-monitor handoff. Deterministic real-store tests
prove AckHalt and pre-save replay, existing and missing checkpoint policies, idempotent bridge
cancellation, and empty registry cleanup. All five Kiroku cells and REV-13 entries are closed;
focused performance passes, so EP-45 resumes for its final candidate matrix.

2026-09-20 UTC: EP-45 pass-two candidate selection rejected short version-1 final-capture data,
introduced a symmetric version-2 workload, and profiled the optimized production runner. The
selected implementation removes terminal closure retention and activity-accounting atomics
without losing idle-intake wakeup or health behavior. The focused 20-pair N1 serial-full result
passes the original throughput, tail-latency, and allocation budgets; the immutable full N1/N4
matrix, live adapters, and 30-minute soak remain open.

2026-09-20 UTC: EP-45 rejected the initial full version-2 N1 result because its ordinary
shutdown cells timed only post-drain cancellation. Workload version 3 adds a meaningful public
graceful-drain scenario, retains repeated cold startup/stop, and makes all 17 scenarios
mandatory in the comparator. Baseline and candidate compile and complete the new workload with
1,000/1,000 acknowledgements; immutable N1/N4 recapture remains open.

2026-09-20 UTC: EP-45 rejected the first full version-3 N1 candidate after all four unordered
`Async 4` scenarios exposed the same allocation and throughput regression. A bisect and ticky
profiles traced the cost to whole-child unmasking. The revised candidate keeps framework
coordination masked and unmasks only owned adapter and handler/finalizer actions. All core,
isolated-GC, metrics, and comparator tests pass; a 40-pair O2 N1 focused comparison passes all 20
affected cells under the original limits. The full N1/N4 matrix, live adapters, and soak remain
open, so EP-45 Milestones 4 and 5 are not complete.

2026-09-21 UTC: EP-45 rejected the full N1 recapture against `c25a9188` after it exposed
confident 9.7% and 11.7% serial throughput regressions from per-message unmasking. Unmasking each
serial region once passes all ten cells in a fresh 40-pair O2 N1 selection run while the
concurrent scheduler boundary remains unchanged. Core and isolated-GC tests pass; a new
committed candidate and complete N1/N4 recapture are still required.

2026-09-21 UTC: EP-44 repaired Kafka's previously broken Nix default package and raised its
deterministic acknowledgement reference-model gate to 1,000 seeds. The live candidate-core
suite, `nix build .#default`, `nix flake check`, and formatting all pass at Kafka commits
`d2725ba` and `35a3e41`. The candidate is not frozen: version/bound changes, the release-owner
disposition of REV-15-L1, and independent review remain mandatory.
