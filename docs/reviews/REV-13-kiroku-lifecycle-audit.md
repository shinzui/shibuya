---
type: Review
title: "Kiroku acknowledgement coupling is explicit but group setup cleanup is incomplete"
description: "Kiroku acknowledgement coupling is explicit but group setup cleanup is incomplete; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-13
subject: mori://shinzui/kiroku/packages/shibuya-kiroku-adapter
subjectKind: component
component: shibuya-kiroku-adapter
reviewedSha: 758b81acddf482b08643acf8802f095e621a3e07
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
---

# Kiroku acknowledgement coupling is explicit but group setup cleanup is incomplete

Read both adapter modules completely, plus the subscriptionAckStream implementation in kiroku-store as supporting dependency evidence. References are relative to `mori://shinzui/kiroku`; source-file artifact URIs are pending.

## P2 — consumer-group factory cleanup is not fully exception-safe

kirokuConsumerGroupProcessorsWith accumulates opened adapters recursively, but installs onException only around the next mkMemberAdapter call. Cancellation after that call returns but before the recursive protected acquisition can strand already-created subscriptions. shutdownCreated uses mapM_, so one throwing shutdown skips remaining adapters. Source evidence only; no asynchronous cancellation injection or live database probe was run.

Mask ownership transfer, bracket the collection acquisition, and attempt every cleanup action while preserving the original error. Regression acceptance: fail member N, inject cleanup failure in an earlier member, and cancel between acquisitions; all acquired subscriptions must terminate.

## Verified source design and limitations

The ack-coupled bridge delivers one event and waits for its TMVar reply; the adapter's non-halt finalizer uses tryPutTMVar. This supplies sequential duplicate-reply protection. AckHalt cancels the underlying subscription without checkpoint advancement. The source wakes through a separate close TVar and reports non-cancellation subscription failure. Shutdown cancels immediately rather than waiting for downstream handlers; a late reply can no longer advance a canceled worker, so applications must tolerate replay.

The adapter's public documentation still says supervised handler exceptions are not finalized and can block the bridge forever. Current Shibuya converts synchronous handler exceptions into AckRetry, so that warning is stale for current core; the optional guard still supplies its own one-second delay policy.

No newly demonstrated event-loss bug was found in the conversion/reply path. No database integration or exact checkpoint durability certification was performed. The source-level factory cleanup finding belongs to this adapter project, not the core GC patch.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
