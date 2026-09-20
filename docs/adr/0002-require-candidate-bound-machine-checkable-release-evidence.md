# Require candidate-bound, machine-checkable release evidence

Status: Accepted

Date: 2026-09-20

## Context

Shibuya's lifecycle audit produced useful but heterogeneous evidence: source reviews,
diagnostic scripts that print known failures, isolated regressions, ordinary test suites, and
explicit statements about work that was not run. A green core suite did not detect several
confirmed lifecycle defects, while some source concerns still require live-service fault
injection. Treating all of these records as equivalent would let a release inherit stale
results or silently omit an excluded component.

The lifecycle remediation initiative spans the core, metrics, Kafka, PGMQ, and Kiroku
adapter repositories. Evidence can become stale whenever any source revision, dependency
solution, compiler, service, seed, or command changes. Performance evidence has the same
problem: an unmatched baseline or an adjusted budget chosen after a regression is observed
does not support a release decision.

## Decision

Lifecycle release evidence is candidate-bound and machine-checkable. The canonical inventory
is `docs/audits/lifecycle-release/findings.json`, schema version 1. It preserves every review
finding, concern, limitation, accepted assumption, positive verification, and explicit
exclusion under a stable review-derived key. Historical reviews remain immutable. Each
in-scope lifecycle boundary has an owning plan and mandatory normal, synchronous-exception,
cancellation, timeout, and repeated-stop cells.

A release candidate manifest identifies exact clean source commits for every included
project, exact package versions, the dependency-solver plan hash, compiler and platform,
service versions, commands and exit codes, seeds, timestamps, and artifact locations. A
release gate rejects evidence whose recorded source or solver identity differs from the
candidate. Diagnostic patches may be recorded with a patch hash, but final release evidence
uses committed clean sources.

The gate distinguishes inventory validation from release validation. Inventory validation
allows open work while enforcing schema integrity, ownership, evidence paths, and justified
exclusions. Release validation rejects open or unconfirmed safety work, missing mandatory
matrix cells, stale evidence, fixed findings without regression tests, and incomplete waiver
records. An excluded component is never marked fixed or certified and is always printed in
the release report.

Only a named human release owner may waive a failed gate or change a failed performance
budget. A waiver records rationale, expiry, affected release scope, and compensating controls;
an agent cannot approve its own waiver. Performance thresholds and execution budgets are set
before remediation measurements and changed only with the same named human approval.

The initial execution budgets are 100 repetitions per deterministic concurrency regression,
1,000 recorded-seed cases per reference model or property workload, both single-capability and
multi-capability RTS runs, and a bounded 30-minute soak for each in-scope adapter at its
documented supported concurrency. The initial regression limits are 5% throughput, 10% tail
or shutdown latency, and 5% allocation or live memory, with paired-run confidence bounds and
separately calibrated absolute idle budgets. Existing stricter limits take precedence.

## Consequences

- Passing tests are necessary but do not imply release readiness unless their source and
  dependency identities match the candidate manifest.
- Every remediation plan appends evidence using the shared schema rather than inventing a
  plan-local format or rewriting historical reviews.
- Source-only concerns remain open until reproduced or disproved. A diagnostic script that
  exits successfully after printing a known defect is not a release regression test.
- Inconclusive measurements fail the gate. Aggregate throughput improvements cannot hide data
  loss, hangs, orphan workers, sustained memory growth, or missing matrix cells.
- The deprecated MessageDB adapter remains visible as out of scope and uncertified rather
  than disappearing from the inventory.
- Publication and deployment remain separately authorized actions; this evidence contract
  produces a verdict, not an automatic release.

## Evidence

The schema, coverage taxonomy, validator, candidate layout, and execution budgets are owned by
[`docs/plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md`](../plans/37-establish-lifecycle-assurance-coverage-and-evidence-gates.md).
Integrated certification is owned by
[`docs/plans/44-certify-the-integrated-lifecycle-release-candidate.md`](../plans/44-certify-the-integrated-lifecycle-release-candidate.md),
and matched performance evidence is owned by
[`docs/plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md`](../plans/45-guard-lifecycle-fixes-against-throughput-latency-and-memory-regressions.md).
