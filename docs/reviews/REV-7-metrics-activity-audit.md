---
type: Review
title: "Activity timestamps remain stale across successful processing bursts"
description: "Activity timestamps remain stale across successful processing bursts; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-7
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Core.Metrics
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

# Activity timestamps remain stale across successful processing bursts

Read the full Core.Metrics module and the Health consumer.

## P1 — healthy later work can be reported stuck

beginProcessing (line 278) records the burst timestamp only when the in-flight count reaches one AND stateActiveRef is False. Normal finishProcessing decrements the counter but never clears stateActiveRef. recordBatchOutcomeMetrics also clears it only on a halt. After the first successful burst, subsequent ordinary bursts reuse its timestamp.

HealthProbe creates a metrics handle, starts and completes one item, waits 100 ms, then starts a second. With a 50 ms stuck threshold, readiness immediately reports one stuck processor. The second item has just begun. The same control flow affects normal batch activity. Under the default threshold this can cause false-unready results after 60 seconds, even for short healthy work.

Refresh the activity model without introducing a race between concurrent finish/start operations. Test separated bursts and sustained throughput; merely measuring the age of an uninterrupted busy period can still misclassify a busy healthy worker.

## Other boundaries

Hot counters use atomic increments, but sampled counters, timestamp and cold state are not a transactional snapshot. Do not demand cross-field exact equality from a concurrent sample. Batch processed/failed counters are based on decisions rather than successful finalization, so dashboards should not infer durable acknowledgements from them.

The stale-burst mechanism was introduced in 4cef985, the 0.8 hot-counter refactor, and persists through the current patch. IR-6 owns the fix and regression.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
