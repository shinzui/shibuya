---
type: Improvement Request
title: Restore readiness after a transient handler exception
description: A retried handler exception leaves processor metrics and readiness failed even while subsequent messages complete successfully.
timestamp: 2026-09-25T21:56:22Z
requestId: IR-7
status: proposed
origin: mori://shinzui/keiro-runtime-kenshou
---

# Restore readiness after a transient handler exception

## Observed behavior

A single synchronous handler exception is converted into `AckRetry (RetryDelay 0)` and finalized. The adapter redelivers that message, the handler succeeds on retry, and later messages continue to complete. Nevertheless, `ProcessorMetrics.state` remains `Failed` and `/health/ready` continues to return 503. This is a transient per-message error, not a terminated processor or a failed finalizer.

The live verification at `mori://shinzui/keiro-runtime-kenshou` is scenario `shibuya/metrics/correctness/ready-recovers-after-transient-handler-exception` in project-relative `kenshou-shibuya/src/Kenshou/Suite/Shibuya/Correctness/Metrics.hs`. The artifact-level URI for that scenario and the run records is pending Mori coverage. The scenario processes 1,200 messages with `Async 8` and 100 ms successful handlers. Exactly one invocation throws; the broker observes one retry, and three processed snapshots continue to increase over ten seconds while a backlog remains. Readiness stays unavailable.

- Historical Shibuya 0.9.0.3: project-relative `runs/01a0da95-49db-75b0-ba3a-8e6acdfb7f58/run-result.json`, expected failure `transient-handler-error-sticks-failed-state`, nonblocking.
- Pinned remediation head `6461c74cda5235e292d221f36621d09910b3b6f0`: project-relative `runs/01a0da97-0f3c-701d-8cd1-b4c17060b3ae/run-result.json`, the same expected failure, nonblocking.
- Hackage 0.10.0.0: the isolated `kenshou-shibuya-test` package suite passes its expected-failure assertion. A sealed full-CLI cohort for this release is pending because the full runtime's `keiro-pgmq` dependency bound excludes `shibuya-core` 0.10.0.0.

## Cause and requested contract

`Shibuya.Internal.Runner.Supervised.processOne` passes a handler exception as `Left` to `finishProcessing` after successfully finalizing the retry. `Shibuya.Core.Metrics.finishProcessing` stores `Failed` in the cold state. Later successful completions advance hot counters, but `sampleMetrics` prefers the cold `Failed` state even when work is in flight or has completed. `Shibuya.Metrics.Health.categorize` treats that state as a failed processor. The architecture reference describes `Failed` as the *last processing* failure; after successful work, it is no longer the last outcome.

Keep the failed-message counter and error telemetry for the exception, while allowing the live processor's state and readiness to recover after successful processing. Preserve failed readiness for terminal processor failure, fatal halt, and finalization failure. Add a regression with a one-shot exception, confirmed retry, continuing successful work, and readiness recovery; include a control that a truly blocked handler becomes stuck after its threshold.

This is distinct from the stale activity-timestamp finding in `mori://shinzui/shibuya/okf/reviews/concepts/REV-7` and from the failed configured-worker retention in `mori://shinzui/shibuya/okf/reviews/concepts/REV-8`. The broad lifecycle request `mori://shinzui/shibuya/okf/improvement-requests/concepts/IR-6` owns the earlier fixes; this request tracks the newly reproduced transient-error state separately.
