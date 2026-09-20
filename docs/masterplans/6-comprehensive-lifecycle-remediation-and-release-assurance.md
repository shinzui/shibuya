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
| 45 | Guard lifecycle fixes against throughput latency and memory regressions | [EP-45](../plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md) | EP-37 | EP-38, EP-39, EP-40, EP-41, EP-43 for final measurements; two-pass, see Dependency Graph | In Progress |
| 38 | Make core processor ownership and termination exception safe | [EP-38](../plans/38-make-core-processor-ownership-and-termination-exception-safe.md) | EP-37 | Existing standalone EP-46 lands first in Master.hs; EP-45 baseline and focused measurements | Not Started |
| 39 | Make metrics health and WebSocket lifecycle reporting trustworthy | [EP-39](../plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md) | EP-37 | EP-38 Milestone 4 snapshot gates lifecycle-aware health; EP-45 measurements | Not Started |
| 40 | Prevent Kafka acknowledgements from skipping unresolved deliveries | [EP-40](../plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries.md) | EP-37 | EP-38 Milestone 3 failure contract gates terminal-acknowledgement acceptance; EP-45 measurements | Not Started |
| 41 | Verify PGMQ acknowledgement and dead-letter recovery under faults | [EP-41](../plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults.md) | EP-37 | EP-38 Milestone 3 failure contract gates exhausted-finalization acceptance; EP-45 measurements | Not Started |
| 42 | Repair MessageDB checkpoint and shutdown lifecycle semantics | [EP-42](../plans/42-repair-messagedb-checkpoint-and-shutdown-lifecycle-semantics.md) | None | None | Cancelled (MessageDB adapter deprecated; owner decision 2026-09-19) |
| 43 | Make Kiroku subscription ownership exception safe | [EP-43](../plans/43-make-kiroku-subscription-ownership-exception-safe.md) | EP-37 | EP-38 integration only, no gated milestone; EP-45 measurements | Not Started |
| 44 | Certify the integrated lifecycle release candidate | [EP-44](../plans/44-certify-the-integrated-lifecycle-release-candidate.md) | EP-37, EP-38, EP-39, EP-40, EP-41, EP-43, EP-45; existing standalone EP-46; existing EP-34 and EP-35 compatibility gates | None | Not Started |

Existing EP-34, EP-35 and EP-46 are not children of this MasterPlan. EP-46 is docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md, the urgent standalone fix for REV-16, which ships as its own patch release and is expected to complete before any child here starts. The exact paths and compatibility responsibilities of all three are recorded in EP-44; their completion must be checked rather than inferred from old status prose. At this revision master plan 5 lists EP-34 and EP-35 as Not Started. EP-46 is Complete: its fix was published as shibuya-core and shibuya-metrics 0.9.0.3 on 2026-09-20, which makes 0.9.0.3 the released baseline for this initiative and moves EP-34's provisional release to 0.9.0.4. Existing EP-36 concerns only the MessageDB adapter and is no longer a prerequisite of anything here.


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
- [ ] EP-45 M1: Capture matched baseline data before remediation.
- [ ] EP-45 M2: Extend production-runner and lifecycle performance workloads.
- [ ] EP-45 M3: Implement and test the statistical performance comparator. EP-45 pauses here.
- [ ] EP-38 M1: Add deterministic regressions for ownership, halt, failures and policies.
- [ ] EP-38 M2: Fix exception-safe resource acquisition and cleanup, and decide the total shutdown bound.
- [ ] EP-38 M3: Make stop/failure wakeups and scheduler ownership reliable.
- [ ] EP-38 M4: Validate capacities, publish the terminal snapshot and verify all core/GC regressions.
- [ ] EP-39 M1: Characterize the published HTTP and WebSocket contract in a new metrics test suite, before any behavior changes, and add it to the release gate.
- [ ] EP-39 M2: Repair activity accounting and lifecycle-aware health.
- [ ] EP-39 M3: Fix WebSocket ownership, enablement and subscriptions.
- [ ] EP-39 M4: Verify endpoint compatibility and accounting together, and retire the metrics package's "unproven" caveat.
- [ ] EP-40 M1: Reproduce Kafka acknowledgement interleavings with a reference model.
- [ ] EP-40 M2: Fix unresolved-delivery tracking and terminal failure propagation.
- [ ] EP-40 M3: Verify recovery and reassignment against a live ephemeral broker.
- [ ] EP-41 M1: Reproduce ambiguous commits and finalizer fault paths.
- [ ] EP-41 M2: Implement durable idempotent DLQ movement.
- [ ] EP-41 M3: Verify leases, outage recovery and restart on ephemeral PostgreSQL.
- [ ] EP-43 M1: Reproduce member acquisition and cleanup ownership gaps.
- [ ] EP-43 M2: Implement exception-safe group ownership transfer.
- [ ] EP-43 M3: Verify acknowledgement and checkpoint recovery with the real store.
- [ ] EP-45 M4: Measure fixed adapters and candidate soaks.
- [ ] EP-45 M5: Publish raw data and the candidate-bound performance verdict.
- [ ] EP-44 M1: Freeze an exact compatible candidate manifest, including the core version and adapter bounds.
- [ ] EP-44 M2: Execute the full fault, restart and soak matrix.
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


## Outcomes & Retrospective


EP-37 completed the coordination foundation: 52 review-derived records, 15 lifecycle
boundaries, 70 mandatory in-scope cells, a 17-test validator, and an append-only candidate/run
layout with fixed execution budgets. Its intentionally incomplete candidate fails with 152
actionable errors and surfaces all five MessageDB exclusions. No open remediation finding is
closed by this result; the ledger now makes those gaps mechanically visible to every later
child and to final certification.


## Revision Notes


2026-09-20 UTC: Reviewed the MasterPlan and all children against docs/reviews, IR-6, the working tree, the three in-scope adapter repositories and NQE 0.6.6, at the project owner's request before implementation. Changes: cancelled EP-42 and removed the MessageDB adapter and EP-36 from scope on the owner's instruction; recorded the newly reproduced REV-16 findings and, because the owner judged them urgent, registered their standalone fix plan EP-46 as an external prerequisite rather than a child; noted the repository's new first ADR; corrected the dependency model so EP-38 gates named acceptance instead of blocking four independent children; defined the two-pass protocol that stops EP-45 from deadlocking plan selection; added integration points for Master.hs ownership, adapter core bounds and changelogs; replaced the prose Progress placeholder with the milestone checklist the specification requires; and corrected EP-39's activity-accounting prescription. The reason throughout is that the plans must actually close the audited defects before a major release, and several drafted details would have left a defect open or the initiative unable to proceed.

2026-09-20 UTC: Recorded that the external prerequisite EP-46 is complete and released as 0.9.0.3. No child, dependency or scope changed; EP-45's baseline capture and EP-44's candidate manifest should now treat 0.9.0.3, not 0.9.0.2, as the latest released source.

2026-09-20 UTC: Widened EP-39 at the project owner's request so that the initiative closes the metrics package's missing test suite: its first milestone now characterizes the full published contract before any behavior changes, adopting the test-suite item of IR-5, and the suite joins the release gate. Added the integration points this creates, golden fixtures shared with any core change that alters an encoder and the release skill's test step shared with the garbage-collection fixes, and recorded the decision. No child, dependency edge or scope boundary otherwise changed.

2026-09-20 UTC: Completed EP-37. Added the complete review and lifecycle-boundary inventory,
tested inventory and release validators, the append-only candidate evidence layout, execution
and initial regression budgets, and ADR 0002. The registry and aggregate progress now mark all
three EP-37 milestones complete; later children consume its schema and candidate-run identity.
