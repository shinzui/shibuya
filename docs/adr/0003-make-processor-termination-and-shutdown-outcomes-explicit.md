# Make processor termination and shutdown outcomes explicit

Status: Accepted

Date: 2026-09-20

## Context

Shibuya previously represented both a handler-requested halt and exhausted adapter
finalization with `ProcessorHalt`. The supervised wrapper caught that exception and
reported successful child completion. With tracing disabled, a permanent acknowledgement,
retry, or dead-letter failure could therefore disappear after live metrics unregistered.
The intake loop also observed its halt flag through an `IORef` outside the STM transaction
that waited on an empty inbox, so concurrent and batch processors could remain blocked until
the source produced another message.

Application ownership had similar ambiguity. Duplicate processor IDs started multiple
children but retained only one handle. Caller cancellation during startup could bypass
cleanup. Graceful shutdown stopped invoking adapters after the first exception, and its only
deadline started after every adapter shutdown returned. Repeated or concurrent stop calls
could invoke an adapter more than once.

## Decision

Represent deliberate halt and infrastructure failure as distinct outcomes. `ProcessorHalt`
continues to mean a graceful handler decision. Exhausted framework-owned finalization throws
`ProcessorFailure`, retaining the failed `MessageId` when one exists, and participates in the
configured supervision policy. The shared stop signal is a `TVar`, read in the same STM
choice as inbox and source completion, so any terminal request wakes blocked intake.

The internal `Master` retains one bounded lifecycle entry per configured processor:
`LifecycleRunning`, `LifecycleDraining`, `LifecycleStopped`, or `LifecycleFailed Text
(Maybe MessageId)`. Live metrics may still unregister, but terminal state remains until the
master is discarded. Metrics and health integrations consume this snapshot rather than
inferring success from the absence of a live metrics entry.

Validate the entire application before acquiring the master. Duplicate IDs return
`DuplicateProcessorId`; nonpositive concurrency returns `InvalidConcurrency`; and values
whose derived two-times buffer would overflow return `ConcurrencyCapacityOverflow`. These
new constructors on exported error types are an intentional breaking change for the next
major release.

Startup masks only ownership transfer and restores interruptibility while application work
runs. A startup exception or caller cancellation stops the master that owns all children
acquired so far. Keyed worker creation, registration, and start-gate release form one masked
ownership transfer; the scheduler stops input and cancels owned workers as soon as any worker
fails.

`ShutdownConfig` keeps `drainTimeout` and adds `totalShutdownTimeout`. The default drain
timeout remains 30 seconds; the total bound defaults to 60 seconds and includes adapter
shutdown. Every adapter shutdown is attempted after synchronous failures. Cancellation,
failure, or expiration always force-stops the master. The first stop caller owns shutdown;
concurrent and later callers observe its cached result, so adapters are invoked once. If
callers race with different configurations, the first caller's configuration wins.

## Consequences

- `StopAllOnFailure` delivers permanent finalization failure once and stops siblings;
  `IgnoreFailures` lets `waitApp` return normally while the terminal snapshot retains the
  processor and message identity.
- Idle Serial, Ahead, Async, partitioned, and batch processors wake promptly on halt or
  failure without waiting for new input.
- Adding `totalShutdownTimeout`, the error constructors, and `ProcessorFailure` changes the
  public source interface and is released only with the planned major version.
- A total shutdown timeout reports `False`, matching an expired drain; synchronous adapter
  failures still throw after all adapters have been attempted and the master has stopped.
- The lifecycle snapshot is deliberately internal. A stable public probe belongs to the
  separate lifecycle-observability design.

## Evidence

Implementation, failing-first evidence, lifecycle matrices, and performance checks are
recorded in
[`docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md`](../plans/38-make-core-processor-ownership-and-termination-exception-safe.md).
The shared release-evidence contract is
[`docs/adr/0002-require-candidate-bound-machine-checkable-release-evidence.md`](0002-require-candidate-bound-machine-checkable-release-evidence.md).
