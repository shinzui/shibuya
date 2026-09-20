---
type: Review
title: "Idle-source halt hangs and exhausted finalizers are treated as graceful completion"
description: "Idle-source halt hangs and exhausted finalizers are treated as graceful completion; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-4
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Internal.Runner.Supervised
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

# Idle-source halt hangs and exhausted finalizers are treated as graceful completion

Read the complete Supervised module; supporting examination covered Ingester, Halt, Finalize, BatchProcessor, Batcher, App, Master, and lifecycle/reliability tests.

## P1 — halt writes do not wake blocked intake

At Supervised.hs:456, inboxToStream reads haltRef outside STM, then waits only on inbox availability or streamDoneVar. A concurrent or batch handler can set haltRef while intake is already blocked. That write wakes neither STM wait source. The processor cannot reach its post-drain halt check until another message or source completion happens.

The probe emits one message then keeps the source idle for ten seconds, acknowledges halt, and observes completion for 300 ms. Serial completes. Unordered Async 2, Unordered Ahead 2, PartitionedInOrder Async 2, and Serial batching do not. The single-message probe explicitly observes the finalizer; the batch probe observes the handler reaching its halt return. Multiple runs reproduce the result. Explicit cancellation cleans up each app. This establishes failure to halt independently of source progress, not that a finite source can never eventually finish.

Use a wakeable halt signal in the same wait protocol; test idle sources, not just finite streams. Preserve the adapter's leased-message/replay contract during cancellation.

## P1 — finalizer exhaustion is swallowed as requested halt

processOne converts exhausted retries to HaltFatal in haltRef. The driver throws ProcessorHalt; runSupervised catches every ProcessorHalt and returns normally. The batch path performs the same conversion in BatchProcessor and catch in runSupervisedBatch. Consequently IgnoreGraceful supervision sees clean completion, not an infrastructure failure.

With StopAllOnFailure and a permanently throwing finalizer, the probe observes four attempts and `Right (Just ())` from waitApp. The documented fail-loud behavior is not delivered to this caller. Tracing can record the error, but tracing may be disabled and unregister removes metrics. Separate requested AckHalt from failed finalization; keep requested halt isolated, but propagate infrastructure failure according to strategy.

## Coverage and limits

Current 212-example tests and the isolated GC regression pass. Existing finite-source tests miss the halt wakeup interleaving. Direct finite batch-driver tests can observe ProcessorHalt while the public supervised wrapper catches it; they do not establish public fail-loud behavior. No production fix is included. IR-6 carries the acceptance tests. The concurrent IORef halt mechanism predates 0.9 (190a3f0); batching later reused it (0adb3e0). This is source-history attribution, not an executable release bisect.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
