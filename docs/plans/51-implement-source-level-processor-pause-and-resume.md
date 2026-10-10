---
id: 51
slug: implement-source-level-processor-pause-and-resume
title: "Implement source-level processor pause and resume"
kind: exec-plan
created_at: 2026-09-30T23:27:06Z
intention: "intention_01m3ta8zgtebmaz00g0snjzy5a"
master_plan: "docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:27:06Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T19:49:01Z
      verdict: "changes-requested"
      note: "Original draft review found API/concurrency and performance-evidence defects; addressed in the accompanying update. Implementation and measured acceptance remain pending."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-10T19:49:01Z
      mode: "update"
      note: "Apply API and performance review: bounded concurrent state, explicit control semantics, basic default, and candidate-bound integrated regression gates."
---


# Implement source-level processor pause and resume

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


An operator who sees a processor misbehaving today has two choices: let it keep pulling
messages, or stop the whole application. After this plan there is a third: pause the
processor. Pause records intake intent. Once the ingester observes it at its next admission check,
it admits no further source pull until resume. A pull already admitted, messages already
buffered in the inbox, and adapter prefetch may still complete and drain; pause neither
cancels a pending adapter poll nor guarantees lease renewal. The pause is
visible immediately as a distinct `paused` state in the processor's metrics, in the
Prometheus gauge, and in every WebSocket frame that carries processor state, and it is
reversible with one call.

You can see it working from a Haskell program with nothing but the public `Shibuya`
module: start an application with `runApp`, call `pauseProcessor appHandle (ProcessorId
"orders")`, observe that the adapter's source is no longer being pulled while `getAppMetrics`
reports `Paused`, then call `resumeProcessor` and watch consumption continue. The test suite
demonstrates each of those observations deterministically, and the Prometheus text of a
paused processor reads `shibuya_processor_state{processor="orders"} 5.0`.

This plan delivers the first item of
`docs/improvement-requests/implement-designed-processor-pause-resume-and-expose-gated-control-endpoints.md`
(IR-4): the core primitive and its public application API. The gated HTTP control
endpoints, and the closure of IR-4, belong to
`docs/plans/52-expose-gated-pause-and-resume-control-endpoints.md`, which cannot compile
without the functions this plan adds. The parent initiative is
`docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`.


## Progress


- [ ] Milestone 1: Add `Shibuya.Internal.Runner.Pause`, gate the ingester before each pull, add the `Paused` state and its sampling rule, add pause handles to the master registry with `ControlOutcome`, and land the deterministic core tests (the six from the design plus the live-adapter, halt, failure, batch, terminal, and unknown-id cases).
- [ ] Milestone 2: Export `pauseProcessor`, `resumeProcessor`, and `isProcessorPaused` from `Shibuya.App` and `Shibuya`, resume every paused processor before adapter shutdown in `stopAppGracefully`, update Health and Prometheus for the new state, update the golden fixtures deliberately, and add round-trip and public-API tests.
- [ ] Milestone 3: Capture paired performance evidence for the gate under `-N1` and `-N4`, then write the documentation, the ADR, and the three changelog entries.


## Surprises & Discoveries


2026-10-10 review: Pause is admission intent, not synchronous source quiescence. State,
timestamp, lifecycle checks and metrics writes must be transactional; shutdown rejects new
control. Deterministic tests must place barriers before and after admission, not assume that
an IO action following a gate check is atomic with a concurrent pause.

2026-09-30 (planning): The design's gate, `Stream.mapM` with a blocking check, would run
after the upstream element has already been produced, so one leased message would sit at
the gate for the whole pause. Checked against the resolved `streamly-core` 0.3.1 source
(`mori://composewell/streamly/packages/streamly-core`, project-relative
`streamly/core/src/Streamly/Internal/Data/Stream/Type.hs`, `zipWithM`): the zipped stream steps its
first argument, and only after that argument yields does it step the second. A gate placed
as the first zipped stream therefore waits before the adapter is pulled at all. See Context
and Orientation for the excerpt.


## Decision Log


- Decision (2026-10-10): Make pause state and lifecycle transitions atomic, return the resulting PauseState, reject control during draining, and document already-admitted pulls. Preserve registerProcessor for unchanged harnesses.
  This revision supersedes conflicting 2026-09-30 design assumptions below.

- Decision: Gate before each pull with `Stream.zipWith (\() msg -> msg) (Stream.repeatM
  wait) source`, not after with `Stream.mapM`.
  Rationale: The design document's stated goal is that a paused processor dequeues nothing
  further after the next admission check; the admitted-poll and prefetch limits are
  documented by the 2026-10-10 update. A gate that runs after the
  element exists defeats that for one message per pause. The zip order is verified against
  the resolved streamly-core release, recorded above.
  Date: 2026-09-30

- Decision: A pause is operator intent and is reported immediately, even while in-flight
  messages drain.
  Rationale: This is the design's section 5 choice: the operator wants to know at once that
  the pause was accepted. The in-flight count travels with the `Paused` state so a reader can
  still see draining progress.
  Date: 2026-09-30

- Decision: `Failed` and `Stopped` win over `Paused` in the sampled state, and a resume after
  a terminal lifecycle failure changes nothing. Transient Failed metrics are not terminal proof.
  Rationale: `docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md`
  makes terminal outcomes explicit and retained; a pause must never hide a failure or make a
  finished processor look controllable.
  Date: 2026-09-30

- Decision: `stopAppGracefully` resumes every paused processor before it calls any adapter's
  `shutdown`.
  Rationale: A paused source is never pulled, so an adapter that ends its stream on shutdown
  could never deliver that end through the gate. Resuming first lets the source end normally;
  forced stop and halt cancel the ingester through its owner regardless, so nothing hangs.
  Date: 2026-09-30

- Decision: Keep the pause primitive in `shibuya-core` and expose it through `Master`-level
  IO functions; no HTTP route is added here.
  Rationale: `docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
  keeps every network exposure in `shibuya-metrics`; EP-52 owns the routes and needs only
  `pauseProcessorIO`, `resumeProcessorIO`, and `isProcessorPausedIO` from this plan.
  Date: 2026-09-30

- Decision (updated 2026-10-10): Preserve existing registerProcessor calls via a wrapper
  that registers Nothing, and report such processors as `ControlNotControllable`.
  Rationale: `registerProcessor` is internal and its callers construct metrics handles
  without a runner; giving them a fake pause handle would let tests pause something that
  cannot be paused. The outcome makes the distinction explicit for EP-52's endpoints.
  Date: 2026-09-30


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


Shibuya is a queue-processing framework. An application defines processors; each processor
is fed by an adapter and hands each message to a handler that returns an acknowledgement
decision. The adapter record in `shibuya-core/src/Shibuya/Adapter.hs` is deliberately tiny:

```haskell
data Adapter es msg = Adapter
  { adapterName :: !Text,
    source :: Stream (Eff es) (Ingested es msg),
    shutdown :: Eff es ()
  }
```

`source` is a Streamly stream. Streamly streams are pull-based: nothing happens until a
consumer asks for the next element, and each ask runs the producer's step function once. For
a queue adapter, an ask is what triggers a poll of the queue, and a polled message is
leased: the queue hides it from other consumers for a visibility timeout, after which an
unacknowledged message becomes visible again and is redelivered. A message that has been
handed to a handler and not yet acknowledged is in flight. Draining means letting in-flight
work finish without starting new work.

The ingester is the thread that pulls from `source`. It lives in
`shibuya-core/src/Shibuya/Internal/Runner/Ingester.hs`:

```haskell
runIngesterWithMetrics metricsHandle source inbox = do
  let mailbox = inboxToMailbox inbox
  Stream.fold Fold.drain $
    Stream.mapM
      ( \msg -> do
          liftIO $ incrementReceived metricsHandle
          liftIO $ send msg mailbox
          pure msg
      )
      source
```

`inbox` is a bounded mailbox (capacity `inboxSize`, default 100) that provides
backpressure: `send` blocks when it is full. `runIngesterAndProcessor` in
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` starts the ingester with
`UIO.withAsync`, unmasking only the adapter code (`unsafeUnmask (runInIO
(runIngesterWithMetrics ...))`), sets `streamDoneVar` in a `finally` when the source ends,
and runs the processor loop in the calling thread. `runIngesterAndProcessorBatch` has the
same shape for batching processors. The processor loop reads the inbox through
`inboxToStream`, a two-branch STM decision: receive from the inbox, or observe that the
source has completed and the inbox is empty, in which case the loop ends. A terminal request
(halt or failure) also marks `streamDoneVar` so an idle loop wakes, as
`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md` records. When
the `withAsync` scope ends for any reason, the ingester thread is cancelled; an STM wait is
interruptible, so a blocked ingester cannot resist cancellation.

Processor state lives in `shibuya-core/src/Shibuya/Core/Metrics.hs`. `ProcessorState` is
today `Idle`, `Processing !InFlightInfo !UTCTime !UTCTime`, `Failed !Text !UTCTime`, or
`Stopped`, where `InFlightInfo` holds `inFlight` and `maxConcurrency`. A `MetricsHandle`
splits hot counters (received, processed, failed, in-flight as atomic counters) from a cold
`TVar ProcessorMetrics`. `sampleMetrics` combines them: the cold state wins when it is
`Failed` or `Stopped`; otherwise the state is `Processing` when the hot in-flight counter is
positive and `Idle` when it is zero. `beginProcessing` and `finishProcessing` are the
hot-path write functions; `finishProcessing` sets the cold state to `Failed` on a handler
error or a halt. JSON instances are hand-written for `ProcessorState` (a `status` member
selects the shape) and derived for `ProcessorMetrics`.

The master in `shibuya-core/src/Shibuya/Internal/Runner/Master.hs` owns a supervisor and a
registry `TVar MasterRegistry` with `liveMetrics :: Map ProcessorId MetricsHandle` and
`lifecycles :: LifecycleSnapshot`, the retained per-processor lifecycle
(`LifecycleRunning`, `LifecycleDraining`, `LifecycleStopped`, or `LifecycleFailed Text
(Maybe MessageId)`) that survives after a processor unregisters its live metrics.
`registerProcessor master pid metricsHandle` inserts both; `unregisterProcessor` removes only
the live metrics. `getAllMetricsIO` and `getProcessorMetricsIO` sample the live handles.
Callers of `registerProcessor` outside the runner are
`shibuya-metrics/test/Shibuya/Metrics/TestSupport.hs`,
`shibuya-metrics/test/Shibuya/Metrics/WebSocketSpec.hs`, and
`shibuya-metrics/bench/WireLoad.hs`.

`Shibuya.App` in `shibuya-core/src/Shibuya/App.hs` is the public entry point. `runApp`
validates configuration, starts the master, and spawns every processor with `runSupervised`
or `runSupervisedBatch`; `AppHandle` holds the master and a map from `ProcessorId` to
`(SupervisedProcessor, QueueProcessor es)`. `stopAppGracefully` elects one shutdown leader,
and its inner `shutdownAndDrain` marks the master and every processor draining, calls each
adapter's `shutdown` with synchronous failures collected, then waits for every processor's
`done` flag with a drain timeout; the total deadline and the unconditional `stopMaster`
surround it. `SupervisedProcessor` in `Supervised.hs` holds `metrics`, `processorId`,
`done`, and `child`.

The metrics package consumes the state. `Shibuya.Metrics.Health.categorize` in
`shibuya-metrics/src/Shibuya/Metrics/Health.hs` sorts each processor into healthy, failed,
or stuck, and `ProcessorHealth` carries `total`, `healthy`, `failed`, and `stuck`; readiness
requires zero failed and zero stuck. `Shibuya.Metrics.Prometheus.stateToInt` maps `Idle` to
1, `Processing` to 2, `Failed` to 3, and `Stopped` to 4 for the `shibuya_processor_state`
gauge, and `inFlightCount` reads the in-flight count out of `Processing`. Both functions are
exhaustive matches and will not compile until they handle the new constructor. The suite
`shibuya-metrics-test` compares exact output against
`shibuya-metrics/test/golden/processor-metrics.json.golden` and
`shibuya-metrics/test/golden/prometheus.golden`, built from `fixtureMetrics` and
`registerPrometheusFixtures` in `TestSupport.hs`, which hold one processor per state.

The design this plan implements is `docs/plans/PROCESSOR_PAUSE_DESIGN.md`. Kept from it:
pausing at the source rather than at the inbox (its Option B), so the next admission
waits after observing pause; a per-processor pause handle built on a `TVar (Maybe UTCTime)`; a `Paused`
processor state that reflects operator intent immediately; idempotent pause and resume;
public functions on the application handle; resuming before shutdown; and its six-test plan.
Changed from it: the gate waits before each pull instead of after (Surprises & Discoveries);
the `Paused` state carries `InFlightInfo` so draining is visible; the handle is registered
with the master so the metrics server can reach it; and the design's section 7, a
`MasterMessage` control-channel extension, is historical material about a master actor that
no longer exists, and nothing here adds one. Its Option C, an adapter-internal pause that
would also gate an adapter's own prefetch buffer, stays future work: messages an adapter has
prefetched ahead of the gate are outside this plan's control and are documented as a limit.

Relevant ADRs, all in `docs/adr/`:
`0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
fixes the package boundary (the pause primitive is core, its exposure is EP-52's) and the
wire rules this plan's JSON follows (camelCase members, snake_case values, additive only).
`0003-make-processor-termination-and-shutdown-outcomes-explicit.md` defines halt versus
failure, the retained lifecycle snapshot, and the shutdown ownership rules that pause must
respect. `0002-require-candidate-bound-machine-checkable-release-evidence.md` sets the
performance budgets in `docs/audits/lifecycle-release/performance-budgets.json`.
`0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` contributes the rule that a
defect test is trusted only after it has been seen to fail. No other ADR applies. The pre-pull gate is verified at the resolved release source via
`mori://composewell/streamly/packages/streamly-core`; the corpus currently delegates zip
stepping to its producer state machine, so recheck the resolved version rather than copying
the historical implementation excerpt blindly.


## Plan of Work


### Milestone 1: the primitive, the gate, the state, and the registry


At the end of this milestone a processor started with `runSupervised` can be paused and
resumed through the master, the pause is visible in sampled metrics, and a dozen
deterministic tests prove the semantics. Nothing public changes yet beyond the new
constructor.

Create `shibuya-core/src/Shibuya/Internal/Runner/Pause.hs`, headed by the same three-line
"Internal module" comment as its siblings, and add it to `exposed-modules` in
`shibuya-core/shibuya-core.cabal`. It defines:

```haskell
data PauseHandle = PauseHandle
  { pauseState :: !(TVar (Maybe UTCTime))
  }

newPauseHandle :: IO PauseHandle
requestPause :: PauseHandle -> IO Bool
requestResume :: PauseHandle -> IO Bool
isPaused :: PauseHandle -> IO Bool
waitWhilePaused :: PauseHandle -> IO ()
```

The single TVar stores Nothing for running and Just the original pause timestamp for paused.
Do not split intent and timestamp across TVar/IORef writes. Provide STM helpers for changing
intent that the master can compose with registry validation and cold metrics updates in one
transaction. IO wrappers obtain wall time before entering STM. Repeated pause preserves the
original timestamp. `waitWhilePaused` uses `readTVarIO`; if paused it waits in interruptible
STM until Nothing. This is an admission check, not an acknowledgement that an already admitted
adapter poll has completed. No lock is held across adapter IO.


Gate the ingester. `runIngesterWithMetrics` gains a `PauseHandle` argument and replaces
`source` in its fold with:

```haskell
Stream.zipWith
  (\() msg -> msg)
  (Stream.repeatM (liftIO (waitWhilePaused pauseHandle)))
  source
```

Verified order, from `streamly-core` 0.3.1 `Streamly/Internal/Data/Stream/Type.hs`:

```haskell
zipWithM f (Stream stepa ta) (Stream stepb tb) = Stream step (ta, tb, Nothing)
  where
    step gst (sa, sb, Nothing) = do
        r <- stepa (adaptState gst) sa
        ...
    step gst (sa, sb, Just x) = do
        r <- stepb (adaptState gst) sb
        ...
```

The first stream is stepped to a `Yield` before the second is stepped, so the wait runs
before each new zipped element is requested. A source can perform many internal Skip steps
or prefetch messages during that one admitted pull; a pause arriving after admission cannot
revoke it. Tests and documentation must expose this limit. Do not use the design's `Stream.mapM` form. Messages
already in the bounded inbox and already in flight continue to completion; that is the
design's accepted drain behavior, and it is why the in-flight count travels with the paused
state. Leave `runIngester` unchanged.

Thread the handle. In `Supervised.hs`, `runIngesterAndProcessor` and
`runIngesterAndProcessorBatch` gain a `PauseHandle` parameter passed to the ingester;
`runSupervised`, `runSupervisedBatch`, `runWithMetrics`, and `runWithMetricsBatch` each call
`newPauseHandle` beside `newMetricsHandle`, pass it down, and store it: `SupervisedProcessor`
gains `pause :: !(Maybe PauseHandle)`, `Just` in all four. The two supervised variants pass
`Just pauseHandle` to `registerProcessorWithPause`. Keep the old registerProcessor wrapper
for existing fixtures and benchmarks. Also thread the handle through EP-49's With variants
when present, preserving their detail level.

Extend the state. In `Shibuya/Core/Metrics.hs` add `Paused !InFlightInfo !UTCTime !UTCTime` to
`ProcessorState`, encoded as `{"status":"paused","pausedAt":<time>,"lastProgress":<time>,"inFlight":n,"maxConcurrency":m}`
with the matching `FromJSON` case, and add:

```haskell
markPaused :: MetricsHandle -> UTCTime -> IO ()
markResumed :: MetricsHandle -> IO ()
```

`markPaused` writes cold state `Paused (InFlightInfo 0 0) since since` unless the cold state is
`Failed` or `Stopped`, which it leaves alone; `markResumed` turns a cold `Paused` into `Idle`
and leaves anything else unchanged. In `sampleMetrics` add one case: a cold `Paused _ since _`
samples as `Paused (InFlightInfo inFlight maxConcurrency) since lastProgress` using the hot in-flight
counter and `maxConcurrencyRef`; the third timestamp is the existing sampler-derived
lastProgress, not pause time. Place this case after the `Failed` and `Stopped` cases and before the
in-flight test, so `Failed` and `Stopped` keep winning. `finishProcessing`'s `setFailed` and
`recordBatchOutcomeMetrics` already overwrite the cold state on failure or halt, which gives
the required precedence for free; add a test rather than new code for it.

Register control. In `Master.hs` replace the live map's value type:

```haskell
data ProcessorEntry = ProcessorEntry
  { metrics :: !MetricsHandle,
    pause :: !(Maybe PauseHandle)
  }

data ControlOutcome
  = ControlApplied !PauseState
  | ControlAlreadyInState !PauseState
  | ControlNotFound
  | ControlNotControllable
  | ControlTerminal
  | ControlDraining
  deriving stock (Eq, Show, Generic)

registerProcessor :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Eff es ()
registerProcessorWithPause :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Maybe PauseHandle -> Eff es ()
pauseProcessorIO :: Master -> ProcessorId -> IO ControlOutcome
resumeProcessorIO :: Master -> ProcessorId -> IO ControlOutcome
isProcessorPausedIO :: Master -> ProcessorId -> IO (Maybe Bool)
pauseProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ControlOutcome
resumeProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ControlOutcome
isProcessorPaused :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe Bool)
```

Define `PauseState = IntakeRunning | IntakePaused !UTCTime`. `ControlApplied` and
`ControlAlreadyInState` carry the state observed in the same transaction as the decision.
`pauseProcessorIO` and `resumeProcessorIO` read the registry and validate the retained
lifecycle inside STM, then change the pause TVar and cold metrics in that same transaction.
Terminal lifecycles return ControlTerminal; unknown IDs return ControlNotFound; entries
without a handle return ControlNotControllable; LifecycleDraining returns ControlDraining.
The cold metrics Failed state alone is not proof of terminal lifecycle (a transient handler
exception can set it). Export internal STM variants of markPaused/markResumed and retain the
IO wrappers for fixture use. No state can be left half-updated by cancellation or a racing
pause/resume. Successful results describe the operation's atomic decision instant; a later
operation or terminal transition may supersede it.

`isProcessorPausedIO` uses the same transactional lifecycle lookup and returns Nothing for
unknown, uncontrollable, terminal, or draining processors. getAllMetricsIO and
getProcessorMetricsIO sample entry.metrics. Keep existing registration callers unchanged;
registerProcessor delegates to registerProcessorWithPause with Nothing.

Shutdown must atomically mark each lifecycle draining and clear its pause TVar and paused
cold state before invoking adapter shutdown. Use a new Master-level drain-and-resume helper
from App; reject subsequent operator pause/resume as ControlDraining. This prevents a racing
HTTP pause from closing the gate again after shutdown resumes it. Do not rely on phaseRef
alone, which is a separate IORef. Terminal state always wins.


Tests go in `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` under a new `describe
"pause and resume"` group, or a new `Shibuya.Runner.PauseSpec` module listed in
`shibuya-core.cabal` and `shibuya-core/test/Main.hs`. Use `startMaster IgnoreAll`,
`runSupervised`, the master-level functions, and the harness style already in that file:
an `IORef` counter, an `MVar` the handler signals, `atomically` with `check` for barriers,
`UIO.timeout` as a failure bound. Never rely on a sleep alone to prove that something did
not happen; instead prove it with a pull counter that the adapter increments before each
element and an `MVar` that releases exactly one pull at a time.

Build a live adapter for the tests: `source = Stream.repeatM pull` where `pull` takes a
release `MVar`, increments a pull `IORef`, and yields the next tracked `Ingested` (use
`mkTrackedIngested` from `Shibuya.Adapter.Mock`); `shutdown` sets a `TVar` that a
`Stream.takeWhileM` on the source observes. The tests, each stated as an observation:

1. Pause stops new admissions: establish a test barrier just before the admission check,
   then pause and release the barrier. Separately test that a pull already past the check
   can complete once and that its next admission blocks. In the pre-admission case: after five messages have been handled, `pauseProcessorIO`
   returns `ControlApplied (IntakePaused _)`; release five more pulls; the pull counter and the processed
   count do not advance within a one-second bound; `resumeProcessorIO` returns
   `ControlApplied IntakeRunning` and the counts then reach ten.
2. Metrics show the paused state: after the pause, `getProcessorMetricsIO` reports `Paused`
   with `pausedAt` equal to the timestamp in `pauseState`; after resume it reports
   `Idle` or `Processing`, never `Paused`.
3. Isolation: two processors on one master; pausing one leaves the other's counts advancing.
4. Graceful shutdown while paused: `runApp`, pause, `stopAppGracefully defaultShutdownConfig`
   returns `True` within its timeout, and the adapter's `shutdown` was called.
5. Idempotence: a second `pauseProcessorIO` returns `ControlAlreadyInState (IntakePaused _)` and `isPaused`
   stays `True`; a second resume returns `ControlAlreadyInState IntakeRunning` and it stays `False`.
6. In-flight completion during pause: a handler blocked on an `MVar` is in flight when the
   pause lands; releasing it lets the message finalize (tracked decision recorded) while the
   state remains `Paused` with in-flight falling to zero.
7. A paused processor requests nothing further after observing pause at admission: with the inbox drained and the processor
   paused, the pull counter is unchanged after every release `MVar` has been offered; this
   is the wait-before-pull property and must be seen failing in an isolated worktree with
   the design's `Stream.mapM` gate substituted (it advances by one).
8. Halt while paused: a handler returning `AckHalt` on the last in-flight message ends the
   processor; `waitApp` returns and the lifecycle snapshot shows `LifecycleStopped`.
9. Failure while paused: an exhausted finalizer on the last in-flight message leaves
   `Failed` in metrics and `LifecycleFailed` in the snapshot; `resumeProcessorIO` then
   returns `ControlTerminal`, and the sampled state is still `Failed`.
10. Batching processors pause and resume the same way through `runSupervisedBatch`.
11. Concurrent pause/resume, cancellation at each transition, and pause racing shutdown
    produce consistent intent/timestamp/state; shutdown wins with ControlDraining.
12. A finished processor (finite source drained, `LifecycleStopped`) returns
    `ControlTerminal`; an unknown id returns `ControlNotFound`; a handle registered with
    `Nothing` returns `ControlNotControllable`.

A test-only gate hook exposes before-admission and admitted-pull barriers, so tests can
distinguish these two states without pretending a gate read and adapter IO are atomic.

Acceptance for the milestone is `cabal test shibuya-core` green with the new examples
counted, and, for test 7, a recorded failing run against the substituted gate.


### Milestone 2: the public API, shutdown ordering, and the metrics package


At the end of this milestone an application author can pause and resume with only the
`Shibuya` module, shutdown works while paused without special handling, and the metrics
server reports the state on every surface.

In `Shibuya/App.hs` add and export:

```haskell
pauseProcessor :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es ControlOutcome
resumeProcessor :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es ControlOutcome
isProcessorPaused :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es (Maybe Bool)
```

each delegating to the master function on `appHandle.master`, and re-export `ControlOutcome
(..)` and `PauseState (..)`. In `Shibuya.hs` add the three functions and `ControlOutcome (..)` and `PauseState (..)` to the "Running an
application" export group; `ProcessorState (..)` is already exported there, so the new
constructor is public without further change. In `stopAppGracefully`'s `shutdownAndDrain`, use the master drain-and-resume transaction
before the adapter shutdown loop. Every controllable entry becomes draining and unpaused
atomically, preserving terminal entries; no operator call can re-pause it during shutdown.


In `shibuya-metrics`: `ProcessorHealth` gains `paused :: !Int` after `stuck`, encoded as an
additive `paused` member; `categorize` adds the case `Paused _ _ _ -> (h, f, s, p + 1)`,
extending the tuple to four counters. However, when paused inFlight is positive and
now minus lastProgress exceeds stuckThreshold, count it as stuck instead of paused. A pause
must not hide an already-stuck handler or restart its progress clock. Only drained or
actively-progressing paused processors are exempt from readiness failure. `stateToInt`
maps `Paused` to 5 and the HELP line becomes
`Current processor state (1=idle, 2=processing, 3=failed, 4=stopped, 5=paused)`;
`inFlightCount (Paused info _ _) = info.inFlight`. In `TestSupport.hs` add a `paused` entry
to `fixtureMetrics` (`Paused (InFlightInfo 1 2) (at 45) (at 44)`, offset 40) and register a paused
processor in `registerPrometheusFixtures` (`markPaused` after one `beginProcessing`), then
regenerate both golden files and check that the only differences are the new `paused`
object, the new gauge line with value `5.0`, the changed HELP text, and the new in-flight
line. Record the golden change in this plan's Decision Log and in the changelog. Add a
`ProcessorState` round trip for the paused shape in `TypesSpec.hs` or `JSONSpec.hs`, and a
`HealthSpec.hs` cases showing a drained paused processor counted under paused with readiness
true, and a paused handler that stops making progress counted as stuck with readiness false,
using the same lastProgress threshold as Processing. Pausing an already-stuck handler must
not make it ready. These are mutually exclusive health categories. Add a `PublicApiSpec.hs` case in `shibuya-core` that imports only `Shibuya`, runs an
application over a `listAdapter`, pauses, reads `Paused` from `getAppMetrics`, resumes, and
stops.

Acceptance: `cabal build all` succeeds; `cabal test shibuya-core` and `cabal test
shibuya-metrics --test-show-details=direct` pass; `curl` against the running example after a
pause shows `"status":"paused"` in `/metrics/<id>` and `5.0` in `/metrics/prometheus`.


### Milestone 3: performance evidence, documentation, ADR, changelogs


The gate adds one `readTVarIO` per message to the ingester and one `Maybe` field per
processor. Prove it is within budget before closing. Build the `lifecycle-load` executable
from the last commit before this plan (baseline) and from the candidate, from clean
worktrees, and run `scripts/audit/capture-performance-paired.ts` for the scenarios
`serial-small-inbox`, `serial-full-inbox`, `ahead-uniform-keys`, `async-hot-key`,
`batch-size`, and `retry-path` under `-N1` and `-N4`, at least ten alternating pairs each,
then `scripts/audit/compare-performance.ts` against
a focused copy of the canonical budgets with only requiredScenarios narrowed to those six.
Also measure startup/shutdown, idle, and graceful drain in the final integrated matrix. Every cell must pass the 5%
throughput, 5% allocation and live-memory, and 10% latency limits; an inconclusive cell is
rerun with twenty pairs; a failing cell is fixed, never waived. Store the datasets and the
verdict under `docs/audits/lifecycle-release/artifacts/ep51-pause-gate/` with a short
`README.md` naming both SHAs, the solver plan hash, compiler, machine, and commands.

Then document. Add a "Pause and resume" section to `docs/architecture/METRICS.md`
describing the `Paused` state, its JSON, the gauge value, the health count, and precedence.
Add one sentence to `docs/architecture/MESSAGE_FLOW.md` at the ingester: the ingester waits
on the processor's pause gate before each pull. Add "Pausing and resuming processors" to
`docs/user/getting-started.md` (the user guide; `docs/USAGE_GUIDE.md` is only an index)
with a runnable example calling `pauseProcessor` and
`resumeProcessor` and the three facts an author needs: in-flight and inbox messages drain,
an adapter's prefetch buffer is outside the gate, and shutdown resumes before stopping.
Update Haddock on every new export. Add a note at the top of
`docs/plans/PROCESSOR_PAUSE_DESIGN.md` stating that it was implemented by this plan with the
wait-before-pull change. Create `docs/adr/<next unused four-digit number>-pause-processors-at-the-adapter-source-and-report-pause-as-operator-intent.md`
in the plain-Markdown format of `docs/adr/0003-...` (Status, Date, Context, Decision,
Consequences, Evidence) covering wait-before-pull, intent-first state, halt and failure
precedence, resume-before-shutdown, and the prefetch limit. Append under an `Unreleased`
heading in `CHANGELOG.md`, `shibuya-core/CHANGELOG.md`, and
`shibuya-metrics/CHANGELOG.md`: breaking source changes (the `ProcessorState` constructor
for exhaustive matches, the `SupervisedProcessor` field, the new `registerProcessorWithPause` function, the `ProcessorHealth` field for direct construction) and additive wire changes
(the `paused` status object, the `paused` health count, gauge value 5 and its HELP text).
If the capability record `docs/capabilities/processor-introspection.md` (CAP-9) gains
evidence, validate the bundle and append to its `log.md` as described in Concrete Steps. Do
not change the status of IR-4; EP-52 closes it.


## Concrete Steps


Run everything from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`, inside the Nix dev shell if
`cabal`, `bun`, or `okf` are missing.

Build and test at every milestone:

```bash
cabal build all
cabal test shibuya-core
cabal test shibuya-metrics --test-show-details=direct
nix fmt
```

`cabal test shibuya-core` runs three suites; all must report their examples and exit zero:

```text
shibuya-core-test: ... examples, 0 failures
shibuya-core-gc-test ... PASS
shibuya-core-gc-finished-test ... PASS
```

Milestone 1 negative control for the wait-before-pull test, in an isolated worktree:

```bash
git worktree add --detach /tmp/shibuya-ep51-gate HEAD
# In the worktree only: replace the zipWith gate with the design's Stream.mapM form.
(cd /tmp/shibuya-ep51-gate && cabal test shibuya-core --test-show-details=direct \
  --test-options='-m "requests nothing further"')
git worktree remove --force /tmp/shibuya-ep51-gate
```

Expected: the mutated run fails that example with a pull count one higher than the paused
count; the unmodified run passes. Record both transcripts in Surprises & Discoveries.

Milestone 3 paired capture (adjust SHAs, hashes, and machine fields to the real values;
read `docs/audits/lifecycle-release/README.md` first):

```bash
git worktree add --detach /tmp/shibuya-ep51-baseline <last-commit-before-this-plan>
(cd /tmp/shibuya-ep51-baseline && cabal build shibuya-core-bench:lifecycle-load)
cabal build shibuya-core-bench:lifecycle-load
mkdir -p docs/audits/lifecycle-release/artifacts/ep51-pause-gate
jq '.requiredScenarios = ["serial-small-inbox","serial-full-inbox","ahead-uniform-keys","async-hot-key","batch-size","retry-path"]' \
  docs/audits/lifecycle-release/performance-budgets.json \
  > docs/audits/lifecycle-release/artifacts/ep51-pause-gate/focused-budgets.json
BASE=$(cd /tmp/shibuya-ep51-baseline && cabal list-bin shibuya-core-bench:lifecycle-load)
CAND=$(cabal list-bin shibuya-core-bench:lifecycle-load)
for RTS in -N1 -N4; do
  bun scripts/audit/capture-performance-paired.ts \
    --baseline-executable "$BASE" --candidate-executable "$CAND" \
    --baseline-output docs/audits/lifecycle-release/artifacts/ep51-pause-gate/baseline${RTS}.json \
    --candidate-output docs/audits/lifecycle-release/artifacts/ep51-pause-gate/candidate${RTS}.json \
    --baseline-label baseline --candidate-label candidate \
    --baseline-production-sha <baseline-sha> --candidate-production-sha <candidate-sha> \
    --harness-sha <identical-benchmark-tree-hash> --solver-plan-hash <normalized-external-solver-hash> \
    --machine-id <machine> --platform <platform> --compiler ghc-9.12.4 --optimization O2 \
    --capabilities ${RTS#-N} --rts "$RTS" --iterations 10 \
    --scenarios serial-small-inbox,serial-full-inbox,ahead-uniform-keys,async-hot-key,batch-size,retry-path
  bun scripts/audit/compare-performance.ts \
    --baseline docs/audits/lifecycle-release/artifacts/ep51-pause-gate/baseline${RTS}.json \
    --candidate docs/audits/lifecycle-release/artifacts/ep51-pause-gate/candidate${RTS}.json \
    --budgets docs/audits/lifecycle-release/artifacts/ep51-pause-gate/focused-budgets.json \
    --output docs/audits/lifecycle-release/artifacts/ep51-pause-gate/verdict${RTS}.json
done
git worktree remove --force /tmp/shibuya-ep51-baseline
```

Expected: each verdict reports `pass` for every metric of every scenario; any `fail` or
`inconclusive` is recorded and resolved before Milestone 3 closes.

If CAP-9 evidence is touched:

```bash
okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall --profile-enforce --log-enforce
okf log add docs/capabilities --kind Update -m "CAP-9: add pause and resume evidence"
```

Commit small conventional commits, each with the trailer block:

```text
MasterPlan: docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md
ExecPlan: docs/plans/51-implement-source-level-processor-pause-and-resume.md
Intention: intention_01m3ta8zgtebmaz00g0snjzy5a
```


## Validation and Acceptance


The plan is complete when all of the following are observable. Pausing a running processor
through `pauseProcessor` returns `ControlApplied (IntakePaused _)`, stops new admissions once the gate observes pause
(a pull already admitted may still complete; the next admission waits), lets in-flight and inbox
messages finalize normally with their decisions recorded once, and reports
`Paused` with `pausedAt` and the live in-flight count from `getAppMetrics`; resuming returns
`ControlApplied IntakeRunning` and pulls continue. A second pause or resume returns
`ControlAlreadyInState` carrying the current PauseState. Pausing one processor does not slow a sibling. Halt or failure of
an in-flight message during a pause ends the processor exactly as it would unpaused, the
state and lifecycle snapshot show it, and a later resume returns `ControlTerminal`.
`stopAppGracefully` completes within its configured bounds while a processor is paused and
calls every adapter's `shutdown`. Batching processors behave identically.

On the wire, `GET /metrics/<id>` for a paused processor returns
`{"status":"paused","pausedAt":"...","lastProgress":"...","inFlight":0,"maxConcurrency":1}` under `state`,
`GET /health/ready` returns `200` with `"paused":1` in `processors`, and
`GET /metrics/prometheus` contains `shibuya_processor_state{processor="<id>"} 5.0`. Both
golden files differ from their pre-plan versions only by the recorded additions. The
paired performance verdicts pass under `-N1` and `-N4` without a waiver. `cabal test
shibuya-core` and `cabal test shibuya-metrics` pass with the new examples counted, and the
negative control for the wait-before-pull test was seen failing.


## Idempotence and Recovery


Every command above can be rerun. Tests create their own masters and adapters and stop them
in `bracket` or `finally`; a failed run leaves no process. Worktrees are created under
`/tmp` with unique names and removed with `--force`; if one is left behind, remove it and
retry. Performance datasets are written to fixed paths under the artifact directory; a
rerun overwrites them, and a partial capture is simply rerun. Regenerating a golden file
overwrites it; before doing so, `git diff` the previous version and keep the diff in the
Decision Log entry. Do not reset the checkout to recover; revert a specific commit if one
turns out wrong. The pause handle is one `TVar` per processor with no external
resource, so there is nothing to clean up on failure.


## Interfaces and Dependencies


New module `Shibuya.Internal.Runner.Pause` (exposed, internal):

```haskell
data PauseHandle = PauseHandle
  { pauseState :: !(TVar (Maybe UTCTime))
  }
newPauseHandle :: IO PauseHandle
requestPause :: PauseHandle -> IO Bool
requestResume :: PauseHandle -> IO Bool
isPaused :: PauseHandle -> IO Bool
waitWhilePaused :: PauseHandle -> IO ()
```

`Shibuya.Internal.Runner.Ingester`:

```haskell
runIngesterWithMetrics :: (IOE :> es) => MetricsHandle -> PauseHandle -> Stream (Eff es) (Ingested es msg) -> Inbox (Ingested es msg) -> Eff es ()
```

`Shibuya.Core.Metrics`:

```haskell
data ProcessorState = Idle | Processing !InFlightInfo !UTCTime !UTCTime | Paused !InFlightInfo !UTCTime !UTCTime | Failed !Text !UTCTime | Stopped
markPaused :: MetricsHandle -> UTCTime -> IO ()
markResumed :: MetricsHandle -> IO ()
```

`Shibuya.Internal.Runner.Supervised`: `SupervisedProcessor` gains `pause :: !(Maybe
PauseHandle)`; `runIngesterAndProcessor` and `runIngesterAndProcessorBatch` gain a
`PauseHandle` argument after the `MetricsHandle`.

`Shibuya.Internal.Runner.Master`:

```haskell
data ProcessorEntry = ProcessorEntry { metrics :: !MetricsHandle, pause :: !(Maybe PauseHandle) }
data PauseState = IntakeRunning | IntakePaused !UTCTime
data ControlOutcome = ControlApplied !PauseState | ControlAlreadyInState !PauseState | ControlNotFound | ControlNotControllable | ControlTerminal | ControlDraining
registerProcessor :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Eff es ()
registerProcessorWithPause :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Maybe PauseHandle -> Eff es ()
pauseProcessorIO :: Master -> ProcessorId -> IO ControlOutcome
resumeProcessorIO :: Master -> ProcessorId -> IO ControlOutcome
isProcessorPausedIO :: Master -> ProcessorId -> IO (Maybe Bool)
pauseProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ControlOutcome
resumeProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ControlOutcome
isProcessorPaused :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe Bool)
```

`Shibuya.App` and `Shibuya` (public):

```haskell
pauseProcessor :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es ControlOutcome
resumeProcessor :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es ControlOutcome
isProcessorPaused :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es (Maybe Bool)
```

with `ControlOutcome (..)` and `PauseState (..)` re-exported from both.

`Shibuya.Metrics.Health`: `ProcessorHealth` gains `paused :: !Int`.
`Shibuya.Metrics.Prometheus`: `stateToInt (Paused _ _ _) = 5`.

Dependencies: `streamly-core` 0.3.1 as resolved (`Stream.zipWith`, `Stream.repeatM`),
`stm`, and `base`; nothing new. Tooling: `cabal`, `bun` for the audit scripts, `okf` for the
capability bundle, `nix fmt` before every commit.

Plan relationships: `docs/plans/52-expose-gated-pause-and-resume-control-endpoints.md` is
the hard dependent; it consumes `pauseProcessorIO`, `resumeProcessorIO`,
`isProcessorPausedIO`, `ControlOutcome`, and the `Paused` state, and must not start its
endpoint milestone until this plan is Complete.
`docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md`
and `docs/plans/50-expose-acknowledged-cursor-progress-per-processor-and-partition.md` also
edit `Shibuya.Core.Metrics`, `sampleMetrics`, and the golden fixtures; the edits are
disjoint in content, so implement them sequentially with this plan in either order and
rebase the later one, keeping every golden change deliberate and recorded.


Revision note (2026-10-10): API and performance review applied. Make pause state and lifecycle transitions atomic, return the resulting PauseState, reject control during draining, and document already-admitted pulls. Preserve registerProcessor for unchanged harnesses. Implementation and performance measurements remain pending.
