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
---

# Comprehensive lifecycle remediation and release assurance

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope


Deliver a release candidate whose processor lifetime, acknowledgements, durable recovery, health reporting and performance are backed by reproducible evidence. Every historical finding receives an explicit disposition; every lifecycle boundary receives normal and fault-path coverage. The final output is a release verdict for exact source revisions and a dependency solution, not a guarantee that all possible bugs have been eliminated.

Include shibuya-core, shibuya-metrics and the adapters owned by mori://shinzui/shibuya-kafka-adapter, mori://shinzui/shibuya-pgmq-adapter, mori://shinzui/shibuya-message-db-adapter and mori://shinzui/kiroku. Registration-service-v2 and unrelated consumer migrations are excluded. Production chaos, package publishing and deployment require separate authorization. General security certification and exactly-once external side effects are not promised.

The starting evidence is docs/lifecycle-audit-progress.md, docs/reviews/REV-1 through REV-15 as indexed by docs/reviews/index.md, and IR-6 in docs/improvement-requests/close-lifecycle-and-health-audit-gaps.md. The audit includes source-only suspicions and targeted runtime reproductions, not comprehensive integration proof. The local source baseline observed during planning is d27448e (0.9.0.2 release commit); historical review source SHAs remain authoritative for reproductions. Recheck HEAD and published state at execution time.

The GC-only repair and dependency/API compatibility work remain coordinated by docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md. Do not hold a separately approved emergency hotfix hostage to this broader initiative, and do not describe that hotfix as comprehensive audit clearance. Do not choose a future version number or new dependency pin merely from this planning document.


## Decomposition Strategy


Nine children are grouped into three phases. Phase A establishes a coverage/evidence contract (EP-37) and begins performance baseline capture (EP-45). Phase B fixes core ownership (EP-38), then trustworthy observability (EP-39) and each adapter's distinct delivery/persistence contract (EP-40–43). Phase C completes performance comparison and integrated release certification (EP-44). Performance baseline work starts before hot-path remediation; its final comparison necessarily consumes the fixed candidate.

One large repair plan would hide ownership and leave integration assumptions implicit. A plan per source file would split failure paths that must be tested together. The selected streams instead have independently observable outcomes, and adapter fixtures stay with their owning repositories. Core ownership remains one cohesive child because startup, halt, finalization, supervision and scheduler cancellation share the same lifetime contract; it has four verifiable milestones.

No local docs/adr corpus existed during discovery. The relevant cross-project decision read through Mori is mori://shinzui/kiroku/okf/adrs/concepts/ADR-4: explicit missing-checkpoint policy, preservation of existing checkpoints, monotonic normal saves, and a separate reset operation. The Kiroku child preserves it. Create local ADRs during implementation for terminal-state ownership, failure-versus-Halt semantics, checkpoint commit boundaries, durable DLQ idempotence, and release/performance evidence policy, following the repository's then-current ADR contract.


## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 37 | Establish lifecycle assurance coverage and evidence gates | [EP-37](../plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md) | None | None | Not Started |
| 45 | Guard lifecycle fixes against throughput latency and memory regressions | [EP-45](../plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md) | EP-37 | EP-38–43 for final measurements | Not Started |
| 38 | Make core processor ownership and termination exception safe | [EP-38](../plans/38-make-core-processor-ownership-and-termination-exception-safe.md) | EP-37 | EP-45 baseline and focused measurements | Not Started |
| 39 | Make metrics health and WebSocket lifecycle reporting trustworthy | [EP-39](../plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md) | EP-37, EP-38 | EP-45 baseline and focused measurements | Not Started |
| 40 | Prevent Kafka acknowledgements from skipping unresolved deliveries | [EP-40](../plans/40-prevent-kafka-acknowledgements-from-skipping-unresolved-deliveries.md) | EP-37, EP-38 | EP-45 baseline and focused measurements | Not Started |
| 41 | Verify PGMQ acknowledgement and dead-letter recovery under faults | [EP-41](../plans/41-verify-pgmq-acknowledgement-and-dead-letter-recovery-under-faults.md) | EP-37, EP-38 | EP-45 baseline and focused measurements | Not Started |
| 42 | Repair MessageDB checkpoint and shutdown lifecycle semantics | [EP-42](../plans/42-repair-messagedb-checkpoint-and-shutdown-lifecycle-semantics.md) | EP-37, EP-38; existing EP-36 | EP-45 baseline and focused measurements | Not Started |
| 43 | Make Kiroku subscription ownership exception safe | [EP-43](../plans/43-make-kiroku-subscription-ownership-exception-safe.md) | EP-37, EP-38 | EP-45 baseline and focused measurements | Not Started |
| 44 | Certify the integrated lifecycle release candidate | [EP-44](../plans/44-certify-the-integrated-lifecycle-release-candidate.md) | EP-37–43, EP-45; existing EP-34–36 compatibility gates | None | Not Started |

Existing EP-34–36 are not new children. Their exact paths and compatibility responsibilities are recorded in EP-42 and EP-44; their completion must be checked rather than inferred from old status prose.


## Dependency Graph


EP-37 defines the evidence schema consumed by every other child. EP-45 begins after it and captures a matched baseline before fixes are accepted. EP-38 owns the core stop/failure and terminal lifecycle interfaces; EP-39–43 cannot be declared complete against an unsettled interface. Once EP-38 is complete, observability and adapter streams can be implemented independently with shared-interface coordination. MessageDB additionally needs the existing EP-36 compatibility migration before integrated tests can compile.

EP-45 has a soft integration dependency on the fixed sources, so its baseline and harness milestones are immediately implementable rather than blocked by a cycle. It completes only when all changed candidate paths have final performance results. EP-44 has hard dependencies on every new child and applicable existing compatibility gates: it certifies their composition, not each child in isolation.

```text
Phase A: EP-37 -> EP-45 baseline/harness ----------------------+
              -> EP-38 -> EP-39, EP-40, EP-41, EP-42, EP-43 --+--+
Existing EP-36 ------------------------------> EP-42          |  |
Phase C: fixed candidate -> EP-45 final performance verdict --+  |
         all evidence + applicable EP-34–36 gates -> EP-44 <----+
```

A hard dependency blocks completion/start under the plan protocol because it supplies a required artifact. A soft dependency permits early work but identifies an integration obligation. No dependency edge authorizes writes to another repository; obtain the necessary workspace permission before implementation there.


## Integration Points


EP-37 owns docs/audits/lifecycle-release/findings.json schema, the coverage taxonomy, scripts/audit/validate-evidence.ts and evidence format. Each remediation child owns entries and artifacts for its assigned findings; EP-44 assembles the candidate manifest and final verdict. Preserve historical reviews and append new candidate review records rather than overwriting original evidence.

EP-38 alone owns application lifecycle, stop/failure signaling, scheduler ownership and the retained internal terminal snapshot. EP-39 owns Core/Metrics.hs and metrics endpoints, consuming that snapshot. Adapter children consume core's finalizer-failure contract and own their adapter delivery state. Neither metrics nor an adapter may quietly reinterpret failed finalization as successful Halt.

EP-40 owns Kafka unresolved-delivery/assignment tracking and broker fixtures. EP-41 owns PGMQ transactional DLQ behavior and database fault fixtures. EP-42 owns MessageDB observed-delivery and persisted-checkpoint state, after existing EP-36's API migration. EP-43 owns Kiroku subscription acquisition/transfer, preserving the accepted upstream checkpoint contract. Cross-project references use the project URIs above with explicitly project-relative paths where artifact-level source URIs remain pending.

EP-45 owns benchmark scenarios, comparator and performance-budgets.json. It uses fixtures supplied by EP-40–43 and produces a candidate-bound verdict consumed by EP-44. Existing EP-34 owns release-skill dependency benchmark policy; coordinate changes there rather than editing that shared policy from two plans. Each remediation child supplies focused performance evidence before closure; the final matrix is mandatory regardless of patch/minor version.

Release acceptance requires every mandatory matrix cell to run, confirmed defects to have red/green tests, source-only concerns to be reproduced or disproved, durable restart behavior to be observed on real ephemeral services, and no stale evidence after source/dependency changes. Proposed starting performance limits are 5% throughput loss, 10% tail/shutdown latency increase, and 5% allocation/live-memory increase, with paired-run confidence bounds and separately calibrated absolute idle budgets. Inconclusive measurements do not pass. Existing stricter budgets win. Changing a failed budget or accepting a residual risk requires a named human release-owner decision, never an automatic agent waiver. No data-loss, hang, orphan-worker, or sustained-memory-growth finding can be hidden by aggregate throughput improvement.

Status is visible in this registry and each child's Progress. During implementation, record timestamped milestone evidence and blockers at every stopping point; never use “audit complete” to mean merely “source read.” The final verdict names exact candidate SHAs, test counts, unexecuted cells, performance results, residual risks, and independent review.


## Progress


No implementation milestones have been completed. All child plans are drafted and Not Started; track actual milestones here when execution begins.


## Surprises & Discoveries


None yet; this section is reserved for implementation discoveries.


## Decision Log


2026-09-19: Separate evidence, core lifecycle, observability, adapter remediation, performance and certification. This makes ownership and independently verifiable outcomes explicit without treating the existing passing suite as comprehensive assurance.

2026-09-19: Preserve the existing hotfix/compatibility master and its responsibilities. The new initiative closes the broader audit and adds missing tests; it does not duplicate releases or claim publication from local version metadata.

2026-09-19: The user explicitly requested performance-regression prevention. Add EP-45 and make its final verdict a hard release gate, with early baseline capture, realistic backpressure, tail latency, allocation, memory, idle CPU and live-adapter coverage.

2026-09-19: Use intention intention_01m2yfmkqxeg9sc0wfmcp4w9fe, created through mina ci as requested, for this master and every child. Plan creation does not authorize implementation, release or cross-workspace writes beyond the requested scope.


## Outcomes & Retrospective


To be filled during implementation and final certification. No finding is closed merely by drafting these plans.
