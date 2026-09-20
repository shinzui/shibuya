# Lifecycle and concurrency audit progress

Updated 2026-09-20 UTC. This is an incomplete audit ledger, not an approval or
a claim that every candidate below is a defect. No production fixes are included.
Registration-service-v2 is out of scope.

## Saved findings

- [REV-1](reviews/REV-1-master-lifecycle-gc-regression.md): historical, runtime-confirmed
  idle linked master GC crash and its introduction. Subsequent master-loop
  removal is recorded separately from the pre-fix evidence.
- [REV-2](reviews/REV-2-application-lifecycle-audit.md): full source review of App;
  shutdown exceptions bypass cleanup, and duplicate processor IDs discard
  lifecycle handles. Runtime probes remain pending.

## Candidates requiring validation

- **Halt wakeup:** `Internal.Runner.Supervised.inboxToStream` reads an IORef halt
  flag before blocking in STM on inbox/stream completion. A concurrent handler
  or batch handler can update the IORef without waking that transaction. Test a
  live, idle source after a handler returns `AckHalt`, not just finite sources.
- **Keyed scheduler failure propagation:** `KeyedScheduler` stores a worker
  exception but emits it only once input ends and all work drains. Test a worker
  failure against an unending input stream, and establish intended fail-fast
  semantics and the reachable production exception paths.
- **Child ownership during cancellation:** inspect the interval between async
  worker allocation and insertion into the scheduler's tracked-worker map.
  Validate masking and cancellation semantics before assigning severity.
- **Finalization exhaustion:** trace the conversion of exhausted acknowledgement
  retries into `ProcessorHalt`, which supervision treats as graceful completion.
  Determine whether this matches the intended stop-all failure contract.
- **Concurrency configuration:** `validatePolicy` does not reject nonpositive
  Ahead/Async limits; keyed scheduling clamps them. Verify the other execution
  path's dependency behavior before claiming a hang or unbounded concurrency.
- **Kafka retry barriers:** check already-buffered records after a seek, including
  a higher-offset record also returning `AckRetry`. Filtering at source yield
  time alone does not establish safety after entry into the framework inbox.
- **Kafka fatal acknowledgement errors:** verify errors deferred to the source
  are still observable when shutdown has already ended polling.

## Source examination so far

Core modules read: App, Internal.App, Policy, Internal.Runner.Master,
Supervised, Ingester, Finalize, Halt, KeyedScheduler, Batcher, and BatchProcessor.
Supporting lifecycle tests were inspected. Reading a module is not equivalent
to completing its behavioral validation or recording an independent approval.

Adapter source inspection has started in
`mori://shinzui/shibuya-kafka-adapter` (public adapter, Internal, Config) and
`mori://shinzui/shibuya-pgmq-adapter` (public adapter and Internal).
MessageDB (`mori://shinzui/shibuya-message-db-adapter`) and Kiroku
(`mori://shinzui/kiroku/packages/shibuya-kiroku-adapter`) remain to be examined.
Adapter-specific review records and runtime/integration checks remain pending.

## Completion criteria

Exercise and record normal completion, halt with idle/live sources, source and
finalizer failures, stop-all versus isolated supervision, cancellation during
startup/work/shutdown, and adapter acknowledgement/shutdown races. Save
component-specific OKF records with exact commits and distinguish executable
evidence from source reasoning. Report unavailable integration environments and
untested boundaries explicitly. Do not close the audit merely because the GC
regression or existing suite passes.
