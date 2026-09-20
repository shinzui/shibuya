---
type: Review
title: "WebSocket cleanup can leak connection slots on disconnect"
description: "WebSocket cleanup can leak connection slots on disconnect; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:codex-cli
  at: "2026-09-20T03:42:33Z"
reviewId: REV-9
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Metrics.WebSocket
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

# WebSocket cleanup can leak connection slots on disconnect

Read the complete WebSocket module with Server routing and Config.

## P2 — acquired slots are not released on every exit

websocketApp acquires a slot before acceptRequest and initial snapshot; the finally is installed only around receiveLoop, after those operations and after async push-thread creation/linking. Exceptions during handshake/setup bypass releaseConnection. In the finalizer itself, sendTextData Goodbye runs before releaseConnection. A peer disconnect can make that send throw, skipping the counter decrement. Repetition can exhaust wsMaxConnections and reject healthy clients.

Bracket slot acquisition/release independently of network sends. Scope push-thread lifetime structurally. A failing goodbye must not prevent local bookkeeping. Required tests: failed upgrade, failed initial snapshot, abrupt peer disconnect, push failure and cancellation; assert connectionCount returns to zero. This is source-confirmed; no loopback WebSocket reproduction was run.

## Additional correctness issues

- **P2:** Server.combinedApp always installs websocketApp and this module never checks enableWebSocket. Setting the flag False only changes the ordinary HTTP route; it does not disable upgrades. Test rejected upgrades when disabled.
- **P3:** Unsubscribe while subscriptions is Nothing does nothing. The comment promises filtering later, but pushLoop interprets Nothing as all processors. This is a real subscription behavior mismatch, not a lifecycle release blocker.
- Removal of a processor produces no removal notification; delta-only clients can retain stale entries. Define a removal/snapshot protocol rather than treating absence as an update.

The connection management code dates to 6fe679a, not the current GC patch. No socket/server state was changed by this review. IR-6 covers cleanup and enablement; existing metrics interface requests may cover protocol refinement.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md).
