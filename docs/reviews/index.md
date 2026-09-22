---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Review

- [Master lifecycle review confirms an abandoned linked mailbox can crash healthy workers](REV-1-master-lifecycle-gc-regression.md) - Examination of the master module confirms the pre-fix GC crash, traces its introduction to 0.8, and identifies the limits of existing lifecycle coverage.
- [Kafka retry barriers can move past an unresolved earlier offset](REV-10-kafka-acknowledgement-audit.md) - Kafka retry barriers can move past an unresolved earlier offset; evidence, boundaries, and required follow-up are recorded.
- [PGMQ lifecycle review retains an ambiguous-commit idempotency risk](REV-11-pgmq-lifecycle-audit.md) - PGMQ lifecycle review retains an ambiguous-commit idempotency risk; evidence, boundaries, and required follow-up are recorded.
- [MessageDB checkpoint and shutdown protocols have multiple lifecycle defects](REV-12-message-db-lifecycle-audit.md) - MessageDB checkpoint and shutdown protocols have multiple lifecycle defects; evidence, boundaries, and required follow-up are recorded.
- [Kiroku acknowledgement coupling is explicit but group setup cleanup is incomplete](REV-13-kiroku-lifecycle-audit.md) - Kiroku acknowledgement coupling is explicit but group setup cleanup is incomplete; evidence, boundaries, and required follow-up are recorded.
- [Master actor removal passes the isolated garbage-collection regression](REV-14-master-fix-verification.md) - Master actor removal passes the isolated garbage-collection regression; evidence, boundaries, and required follow-up are recorded.
- [Batcher source review finds scoped cleanup and documents accumulation limits](REV-15-batcher-lifecycle-audit.md) - Batcher source review finds scoped cleanup and documents accumulation limits; evidence, boundaries, and required follow-up are recorded.
- [Master actor removal leaves a childless supervisor that can still kill its caller during garbage collection](REV-16-childless-supervisor-gc-residual.md) - Master actor removal leaves a childless supervisor that can still kill its caller during garbage collection; evidence, boundaries, and required follow-up are recorded.
- [RC2 lifecycle release assurance is complete and candidate-bound](REV-17-rc2-release-assurance-review.md) - Independent review approves the exact RC2 lifecycle release dossier with no blocking findings.
- [Kiroku adapter release packaging preserves the approved runtime candidate](REV-18-kiroku-adapter-release-packaging-review.md) - Independent supplemental review approves the packaging-only successor used for the Kiroku adapter release.
- [Application lifecycle audit finds shutdown cleanup and duplicate identity defects](REV-2-application-lifecycle-audit.md) - Source review of App identifies lost processor handles and missing exception-safe shutdown cleanup; runtime reproduction remains pending.
- [Runtime audit confirms lost processor handles and exception-unsafe lifecycle cleanup](REV-3-app-runtime-audit.md) - Runtime audit confirms lost processor handles and exception-unsafe lifecycle cleanup; evidence, boundaries, and required follow-up are recorded.
- [Idle-source halt hangs and exhausted finalizers are treated as graceful completion](REV-4-supervised-halt-and-failure-audit.md) - Idle-source halt hangs and exhausted finalizers are treated as graceful completion; evidence, boundaries, and required follow-up are recorded.
- [Keyed scheduler retains worker failures until input exhaustion](REV-5-keyed-scheduler-audit.md) - Keyed scheduler retains worker failures until input exhaustion; evidence, boundaries, and required follow-up are recorded.
- [Nonpositive concurrency values are accepted and can remove concurrency limits](REV-6-concurrency-policy-audit.md) - Nonpositive concurrency values are accepted and can remove concurrency limits; evidence, boundaries, and required follow-up are recorded.
- [Activity timestamps remain stale across successful processing bursts](REV-7-metrics-activity-audit.md) - Activity timestamps remain stale across successful processing bursts; evidence, boundaries, and required follow-up are recorded.
- [Readiness loses failed processors and liveness survives master shutdown](REV-8-worker-health-audit.md) - Readiness loses failed processors and liveness survives master shutdown; evidence, boundaries, and required follow-up are recorded.
- [WebSocket cleanup can leak connection slots on disconnect](REV-9-websocket-lifecycle-audit.md) - WebSocket cleanup can leak connection slots on disconnect; evidence, boundaries, and required follow-up are recorded.
