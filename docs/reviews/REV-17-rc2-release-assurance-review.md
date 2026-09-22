---
type: Review
title: "RC2 lifecycle release assurance is complete and candidate-bound"
description: "Independent review approves the exact RC2 lifecycle release dossier with no blocking findings."
generated:
  by: process:codex-cli
  at: "2026-09-22T05:14:00Z"
reviewId: REV-17
subject: mori://shinzui/shibuya/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance
subjectKind: component
component: Shibuya lifecycle release candidate RC2
reviewedSha: f3de2cdbbb1efe1ef984e98cd562d29a5e0edfa3
coverage: full
reviewedAt: "2026-09-22T05:14:00Z"
reviewerKind: model
reviewer: process:codex-cli/candidate-review
provider: openai
model: gpt-6-astra
effort: high
outcome: approved
dimensions:
  - correctness
  - test-coverage
  - performance
  - operability
  - security
  - documentation
context: >-
  Independent release-assurance rereview of exact dossier commit f3de2cd. Full
  covers the candidate manifest, inventory, source/version/bound spot checks,
  functional and performance provenance, raw artifact hashes, external delivery
  ledgers, human risk decisions, validator controls, and publication ordering.
  It is not a claim that unknown defects are impossible.
---

# RC2 lifecycle release assurance is complete and candidate-bound

## Verdict

Approved. No blocking finding remains for the exact RC2 dossier at
`f3de2cdbbb1efe1ef984e98cd562d29a5e0edfa3`.

## Candidate identity

The six evidence runs in
[`release-candidate-rc2.json`](../audits/lifecycle-release/candidates/release-candidate-rc2.json)
share solver hash `1ebf23d528595d2fed2b3cf6492a5ca03efeec80229b168edc023122cc730e27`
and this complete source map:

- Core/Metrics: `e28a95893a534a15302529850eea54f6e0682de0`
- Kafka: `adadf9f52c7ca235fc41f5d7d3e95494735530ab`
- PGMQ: `6ce44abb28c983ede774ac8c6a9ada9c96b0a65f`
- Kiroku: `407cb223f7ba5007d36cc77550d8489a1ae7206d`

The dossier commit is later than the Core/Metrics production SHA because it adds
only assurance evidence and plans. The released package trees are unchanged from
the measured candidate. Any later runtime source or dependency-solution change
invalidates this approval.

## Evidence checked

- Release validation passes 52 findings, 15 boundaries, and 70 mandatory cells,
  while printing all five MessageDB entries as `UNCERTIFIED`.
- Validator tests pass 20/20; comparator tests pass 8/8; soak-analyzer tests pass
  4/4. Mutated project SHA, solver hash, and missing human-acceptance controls are
  independently rejected.
- Core 236 and Metrics 52 examples pass under N1/N4, both isolated GC suites pass,
  and all 1,600 deterministic schedule executions pass.
- Kafka passes 53 tests per RTS cell, PGMQ 177, and Kiroku Store 308 plus adapter
  38, including their live-service paths.
- Paired performance passes 84/84 cells under both N1 and N4. Nine live-adapter
  cells have exact produced/processed identity sets and zero discrepancies,
  failures, final backlog, or sustained retained-heap growth.
- Real-wire capture completes 100,000 readiness requests and 10,000 WebSocket
  cycles with zero errors and no residual connection slots.
- All recorded solver, project/freeze, schedule, performance, wire, and summary
  hashes match their artifacts.

## Accepted and unsupported scope

REV-15-L1 is a named human acceptance for Shibuya 0.10.x, expiring at
`2026-12-31T23:59:59Z` or before 0.11.0.0. Callers must bound distinct in-progress
batch-key cardinality. Release documentation retains the accepted conservative
703-byte-per-additional-key envelope over 1,000–50,000 tested keys; RC2's fresh
measurements are lower at 696 bytes/key under N1 and 649 under N4.

MessageDB is deprecated, unsupported, and uncertified. Kafka remains serial and
has no adapter DLQ producer; cooperative rebalancing requires the documented
fencing helper. PGMQ and Kiroku retain documented at-least-once replay behavior.
Uninterruptible user code can exceed ordinary shutdown guarantees. Metrics has no
built-in authentication; wildcard binding is an operator-controlled deployment
choice.

## Publication constraint

Publish Core first. Metrics, Kafka, and PGMQ must wait for Core to be visible on
Hackage. Publish Kiroku Store before the Kiroku adapter, and publish the adapter
only after both Core and Kiroku Store are visible.
