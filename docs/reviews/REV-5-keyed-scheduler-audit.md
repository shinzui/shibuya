---
type: Review
title: "Keyed scheduler retains worker failures until input exhaustion"
description: "Keyed scheduler retains worker failures until input exhaustion; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-5
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Internal.Runner.KeyedScheduler
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

# Keyed scheduler retains worker failures until input exhaustion

Read the entire module and its callers in Supervised and BatchProcessor.

## P2 — worker failure does not stop an unending stream

runWorker records an exception as firstFailure. nextSchedulerStep (line 156) continues dispatching pending work and only returns that exception when inputDone, an empty pending queue, and zero running workers coincide. An infinite input never satisfies this condition.

The direct scheduler probe throws from item zero, then increments a counter on successors. It times out after 300 ms with over 250 successors processed and no propagated error. The exception is not lost from memory; it is indefinitely deferred. Input is deliberately unending, so this is not a claim about finite-stream eventual propagation.

Handler and finalizer exceptions are normally translated by the runner, so this direct probe does not establish that every ordinary handler exception takes this path. Exceptions in surrounding processing/tracing or other internal callers can. Stop intake on worker failure, settle/cancel owned children according to the contract, and throw without awaiting upstream exhaustion.

## Ownership and bounds

Per-key admission is atomic; running and pending bounds are enforced; same-key work remains serialized. Cancellation cleanup snapshots tracked workers and cancels them. There is an unmasked interval between async allocation and insertion into the worker map. The start gate prevents the worker action from running before registration, reducing the impact to an untracked gate waiter if cancellation lands there; no deterministic escaped-handler reproduction was established. Harden allocation/registration together when changing the scheduler.

Introduced by 88befae (first contained in local tag v0.8.0.0). The current GC fix does not change this module. IR-6 tracks failure propagation and cancellation regressions.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
