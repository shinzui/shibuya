---
type: Review
title: "Batcher source review finds scoped cleanup and documents accumulation limits"
description: "Batcher source review finds scoped cleanup and documents accumulation limits; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-15
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Internal.Runner.Batcher
reviewedSha: 851c7c9db5d47593e2bd2899802c23bb06a231f7
coverage: full
reviewedAt: "2026-09-20T03:42:33Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-6-astra
effort: medium
outcome: commented
dimensions:
  - correctness
  - test-coverage
  - operability
  - documentation
context: >-
  Lifecycle and concurrency examination of the named component. Full refers to
  source coverage at this commit, not exhaustive testing or security certification.
  Executed probes and source-only findings are explicitly distinguished below.
---

# Batcher source review finds scoped cleanup and documents accumulation limits

Read the complete Batcher module, supporting BatchConfig validation, BatchProcessor and Supervised integration, and relevant suite coverage.

The pure arrival/tick/flush stages preserve per-key arrival order. Runtime state updates and output admission share an STM transaction. The input consumer sets done in finally; drainQueue checks its Async result, so input failure is not silently treated as a clean end. The stream bracket owns consumer and ticker cancellation. Existing core batch tests pass in the 212-example suite.

The common halt problem is in the upstream inbox wait protocol, not fixed by the ticker: ticking output state cannot wake inboxToStream's unrelated STM transaction. The Supervised record owns that finding.

The completed-batch queue is bounded by capacity plus one emission burst, not strictly by capacity; the code documents that. In-progress distinct batch keys are not constrained by the inbox size, so high-cardinality input and long batch timeouts can retain substantial memory. This is a documented-design/resource-bound caveat, not an observed leak or measured performance regression. Ticker exceptions are not independently monitored by the output loop; no failing supported configuration was demonstrated.

No new deterministic defect beyond the cross-module halt finding was established in this module. This record does not claim exhaustive scheduler interleavings, unbounded-cardinality safety, or benchmark certification.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
