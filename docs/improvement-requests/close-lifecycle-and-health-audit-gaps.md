---
type: Improvement Request
title: Close the lifecycle and health gaps exposed by the release audit
description: Correct halt wakeups, failure propagation, resource cleanup, identity validation, concurrency limits, and misleading worker health.
timestamp: 2026-09-20T03:36:56Z
requestId: IR-6
status: proposed
origin: mori://shinzui/shibuya/okf/reviews/concepts/REV-3
---

# Lifecycle and health remediation

The completed lifecycle audit is summarized in
[the audit report](../lifecycle-audit-progress.md). This request tracks production
remediation; the audit and its diagnostic probes do not implement these fixes.

## Required corrections and acceptance

1. **Halt wakeups:** make the halt signal part of the blocking wait protocol.
   A live source that produces one message and then remains idle must permit
   `waitApp` to finish after an acknowledged halt in Serial, Ahead, Async,
   partitioned, and batch modes. Check source-thread cleanup and queued leases.
2. **Infrastructure failure propagation:** exhausted finalization is not a
   requested graceful halt. Preserve the failed message identity, stop siblings
   and propagate under `StopAllOnFailure`; retain observable failure under
   `IgnoreFailures`. Test ordinary and batch paths, with tracing disabled too.
3. **Exception-safe ownership:** protect startup acquisition/ownership transfer
   against cancellation. Ensure adapter shutdown errors or cancellation cannot
   bypass supervisor cleanup or leave later adapters unsignalled. Preserve the
   original exception; do not blanket-swallow cancellation. Define any total
   shutdown deadline separately from the existing drain timeout.
4. **Identity validation:** reject duplicate processor IDs before any startup
   effects, including ordinary/batch mixtures.
5. **Scheduler failures:** propagate a worker exception without waiting for an
   unending input stream; stop intake and clean up workers. Test failure with
   pending same-key work and verify no orphaned threads.
6. **Concurrency bounds:** reject nonpositive Ahead/Async values consistently
   before startup. Guard arithmetic overflow when deriving buffer sizes.
7. **Health:** retain configured processor identity and terminal failures for
   readiness decisions. Do not infer supervisor liveness from reading a metrics
   TVar. Reuse the public probe work in IR-1 where appropriate.
8. **Activity metrics:** a new processing burst must not inherit an ancient
   timestamp. Define and test healthy continuous throughput as well as isolated
   short bursts and genuinely stuck handlers. Preserve concurrent correctness.
9. **WebSocket lifecycle:** release acquired slots on handshake, snapshot,
   receive, push, cancellation, and goodbye-send failure. Use structured child
   ownership. Honor the WebSocket enable flag on upgrade requests.

Promote the diagnostic scenarios in `scripts/audit/` into automated regression
tests asserting the corrected behavior. In particular, finite-only source tests
do not cover idle-source halt, and the metrics package currently has no Cabal
test suite. Include loopback WebSocket disconnect/handshake tests.

## Release boundary

These are independent of the already-removed idle master actor. They predate the
current master-loop patch; do not describe them as regressions introduced by that
patch. A broad lifecycle/readiness release should not claim these guarantees
until the high-priority findings are corrected and the regressions pass. A
narrow emergency GC hotfix can be assessed separately with these inherited risks
explicitly disclosed; that is a release-owner decision, not an audit approval.

Kafka, PGMQ, MessageDB, and Kiroku findings belong to their respective projects
and are described in their review records, not silently assigned to this core
request. No external repository has been modified by this audit.
