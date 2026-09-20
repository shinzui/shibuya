---
type: Review
title: "Readiness loses failed processors and liveness survives master shutdown"
description: "Readiness loses failed processors and liveness survives master shutdown; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-8
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Metrics.Health
reviewedSha: 851c7c9db5d47593e2bd2899802c23bb06a231f7
coverage: full
reviewedAt: "2026-09-20T03:42:33Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-6-astra
effort: medium
outcome: changes-requested
dimensions:
  - correctness
  - test-coverage
  - operability
  - documentation
context: >-
  Lifecycle and concurrency examination of the named component. Full refers to
  source coverage at this commit, not exhaustive testing or security certification.
  Executed probes and source-only findings are explicitly distinguished below.
produced:
  - mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6
---

# Readiness loses failed processors and liveness survives master shutdown

Read Health completely, plus JSON routing, Master registry operations and Supervised cleanup.

## P1 — readiness reports success after a required worker exits

Supervised unregisters every processor at exit, including failure. checkReadiness counts only the current metrics map and treats zero failed/stuck processors as ready, including an empty map. HealthProbe starts a processor whose source throws under IgnoreFailures, waits for its completion, and observes:
`ready = True, total = 0, failed = 0, stuck = 0`.

This is not an assertion that an intentionally empty application must always be unready. It is loss of the distinction between intentionally empty and unexpectedly missing configured workers. Keep expected worker identities/terminal outcomes in a lifecycle snapshot and base readiness on that contract.

## P2 — liveness is a successful TVar read, not supervisor health

After stopMaster the probe still reports `alive = True`. getAllMetricsIO reads shared state regardless of supervisor termination. The documentation says this checks whether the master is responding, but there is no message/response or lifecycle check. Define process-level versus worker-level liveness explicitly and expose stopped/failed state for worker probes.

Dependency checks are run sequentially without a library timeout or exception normalization; their providers must currently enforce their own deadlines. No slow-dependency injection was run.

The metrics package has no Cabal test suite (`cabal test shibuya-metrics` reports no tests). IR-1 already requests a public worker probe contract; IR-6 adds the concrete regression acceptance. These issues existed before the actor removal; direct-state metrics reads do not prove worker health.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
