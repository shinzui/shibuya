---
id: 33
slug: remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers
title: "Remove the idle linked master loop that deadlocks bare waitApp callers"
kind: exec-plan
created_at: 2026-09-16T22:33:21Z
master_plan: "docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T22:33:21Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-16T23:13:49Z
      mode: "update"
      note: "Adopted as EP-1 of master plan 5; frontmatter gains master_plan, body unchanged"
---

# Remove the idle linked master loop that deadlocks bare waitApp callers

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Today a program that starts a shibuya application and then simply waits for it — `runApp`
followed by `waitApp`, holding nothing else — dies within a few seconds with:

```text
ExceptionInLinkedThread (ThreadId 33) thread blocked indefinitely in an STM transaction
```

This is not a misuse. It is the shape shibuya-core's own `RunnerSpec` uses, and it is the shape
of every single-processor worker in `mls-service-v2` (`queue-worker run-area-details-cache`
and its siblings), all of which crash on startup today. The only reason the multi-processor
worker there survives is that its Warp metrics server happens to hold a reference to the master.

The cause is a thread shibuya no longer needs. `startMaster` spawns a "master loop" actor that
blocks forever on a mailbox, and links it to the caller. Nothing in the codebase ever sends to
that mailbox — the two operations it used to serve, registering and unregistering a processor's
metrics, already write the metrics `TVar` directly. When nothing outside the loop references
its mailbox, GHC's runtime correctly concludes the thread can never wake, throws
`BlockedIndefinitelyOnSTM` at it, and the link forwards that to the caller as a crash.

After this plan, the master loop is gone. `runApp` then `waitApp` runs for as long as the
processors run, whether or not the caller keeps the handle around, and a regression test that
fails on today's code proves it:

```bash
cabal test shibuya-core-test --test-options='-m "survives major collections"'
```

The public API does not change. `Master` stays the opaque type that `getAppMaster` returns and
`getAllMetricsIO` reads; only the internal module `Shibuya.Internal.Runner.Master` loses its
dead actor protocol.


## Progress

- [ ] Milestone 1: Add the regression test and confirm it fails on the current code.
- [ ] Milestone 2: Remove the master loop, its mailbox, and its message type; make the test pass.
- [ ] Milestone 3: Update the documentation that still describes the master as an actor.
- [ ] Milestone 4: Changelog entry and release.
- [ ] Milestone 5: Consumer follow-up in `mls-service-v2` (bump the pin, confirm the isolation subcommands run).


## Surprises & Discoveries

These were found while diagnosing the crash from the consumer side, before this plan was
written; they are recorded here because the plan rests on them.

**The master's mailbox has no senders.** `registerProcessor` and `unregisterProcessor` in
`shibuya-core/src/Shibuya/Internal/Runner/Master.hs` are plain `atomically $ modifyTVar'
master.state.metrics ...`; they do not go through the inbox. A search of the whole repository
for sends to `master.inbox` or uses of the `MasterMessage` constructors outside `Master.hs`
finds none. The `MasterMessage` type, `handleMessage`, and `masterLoop` are dead code left over
from the hot-path work that moved metrics reads and writes onto the `TVar` directly
(`docs/plans/26-reduce-per-message-hot-path-overhead.md` removed the query constructors; the
register/unregister path went the same way).

**The failure is a reachability question, not a timing one.** GHC treats a thread blocked in
STM as deadlocked when nothing reachable from a garbage-collection root references the `TVar`
it waits on. A thread sleeping in `threadDelay` or blocked in a foreign call is a root, so an
ingester polling a queue keeps its own inbox alive. The master loop's inbox is referenced by
exactly two things: the loop's own stack, and the `Master` record. If the caller keeps the
`Master` reachable — `mls-service-v2`'s `run-all-queues` passes `getAppMaster handle` into a
Warp application closure — the runtime never flags the loop. If the caller only calls
`waitApp`, GHC selects `appHandle.processors` out of the record, the `Master` becomes garbage,
and the first major collection resurrects the loop with `BlockedIndefinitelyOnSTM`. Because
`startMaster` linked it, the caller dies too. The consumer-side census that established this
is in `mori://tan/mls-service-v2/plans/101-find-and-fix-the-queue-worker-s-per-message-memory-retention`.

**shibuya-core's own tests already work around it.** `shibuya-core/test/Shibuya/RunnerSpec.hs`
calls `stopApp` immediately after `waitApp` with the comment "Without this the idle master
blocks forever on its mailbox and the RTS eventually raises BlockedIndefinitelyOnSTM, which
propagates through the link as a flaky ExceptionInLinkedThread landing on whichever test
happens to be running when GC fires." That is the same defect observed as a flake rather than
a crash, because a test process holds more references than a worker does.

**NQE links every process to its creator, including the supervisor.** `nqe-0.6.6`'s
`Control.Concurrent.NQE.Process.process` runs `withAsync (p i) (\a -> link a >> ...)`, so the
supervisor `startMaster` creates is also a linked actor blocked in STM. It does not trip the
detector today because every live child references `master.state.supervisor` through the
`unregisterProcessor master procId` and `propagateFailures` closures, and children are alive
whenever an adapter is polling. Removing the master loop does not change that, but the
regression test must run an idle app through several major collections precisely so that this
residual linkage is exercised rather than assumed.


## Decision Log

- Decision: Delete the master loop rather than keep it alive with a `StablePtr` or by making
  children hold its mailbox.
  Rationale: The loop serves no messages. A `StablePtr` root would preserve a thread whose only
  purpose is to exist, and threading the mailbox through child closures would rely on GHC not
  optimising a free variable away — fragile, and it would still leave a linked actor that can
  never do anything. Removing it is smaller, faster, and removes the class of bug.
  Date: 2026-09-16

- Decision: Keep the `Master` type name and the public accessors unchanged; shrink the record
  to its state.
  Rationale: `Shibuya.App` exports `Master` abstractly, and `getAppMaster`, `getAllMetrics`,
  `getAllMetricsIO`, `getProcessorMetrics`, and `getProcessorMetricsIO` are what consumers and
  `shibuya-metrics` use. None of them need the mailbox or the async. Keeping the name means no
  consumer changes.
  Date: 2026-09-16

- Decision: Treat this as a minor release (`0.9.1.0`), not a major one.
  Rationale: The removed names (`MasterMessage (..)`, the `handle` and `inbox` fields of
  `Master`) are exported only from `Shibuya.Internal.Runner.Master`, which
  `docs/plans/25-pre-1-0-public-api-cleanup.md` moved under `Shibuya.Internal.*` with a
  no-stability Haddock banner, and which the 0.9.0.0 changelog describes as internal with
  `Master` abstract. A search of `shibuya-pgmq-adapter`, `shibuya-kafka-adapter`,
  `shibuya-message-db-adapter`, `shibuya-metrics`, `keiro`, `kotei`, `rei`, and
  `mls-service-v2` finds no use of those names; the benchmarks import only `startMaster` and
  `stopMaster`. The release skill makes the final call from the diff; if it insists on PVP
  strictness for exposed modules the bump becomes `0.10.0.0` and the adapters' `^>=0.9` bounds
  need a follow-up.
  Date: 2026-09-16

- Decision: Keep the `stopApp` calls in `RunnerSpec` but rewrite their comments.
  Rationale: Stopping an app after waiting for it is correct cleanup regardless of this bug;
  only the justification ("otherwise the linked master deadlocks") stops being true.
  Date: 2026-09-16


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

### The pieces involved

shibuya is a supervised queue-processing framework. An application is started with `runApp`
in `shibuya-core/src/Shibuya/App.hs`, which builds a *master* and then spawns one *supervised
processor* per queue under it. Three files matter here.

`shibuya-core/src/Shibuya/Internal/Runner/Master.hs` defines the master. `startMaster` creates
an NQE supervisor (NQE is the actor library shibuya uses for supervision; a "supervisor" is
an actor that owns child threads and restarts or stops them according to a strategy), a
`TVar (Map ProcessorId MetricsHandle)` holding every processor's metrics handle, and — the
subject of this plan — an actor of its own:

```haskell
  masterInbox <- newInbox
  masterHandle <- async $ masterLoop masterState masterInbox
  link masterHandle
```

`masterLoop` is `forever $ receive inbox >>= handleMessage state`, and `handleMessage` handles
three `MasterMessage` constructors — `RegisterProcessor`, `UnregisterProcessor`, `Shutdown` —
all of which only modify the metrics `TVar`. The `Master` record carries `handle :: Async ()`,
`state :: MasterState`, and `inbox :: Inbox MasterMessage`. `stopMaster` cancels the
supervisor and then the async.

`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` spawns each processor as a child of
`master.state.supervisor`, registers its metrics handle with `registerProcessor` before the
child starts and unregisters it in a `finally` when the child ends, and links the child to the
caller when `master.state.propagateFailures` is set. It never touches `master.inbox` or
`master.handle`.

`shibuya-core/src/Shibuya/App.hs` holds `runApp` (calls `startMaster`, spawns the processors,
returns an `AppHandle` of the master plus the processor map), `waitApp` (an STM transaction
that blocks until every processor's `done` `TVar` is `True`), `stopAppGracefully` (drains,
then `stopMaster`), and `getAppMaster`. `Shibuya.App` re-exports `Master` abstractly together
with `getAllMetrics`, `getAllMetricsIO`, `getProcessorMetrics`, and `getProcessorMetricsIO`,
all of which read `master.state.metrics`.

### Two terms

A **linked** thread, in the sense of `Control.Concurrent.Async.link`, is one whose failure is
re-thrown in the thread that linked it, wrapped as `ExceptionInLinkedThread`. shibuya links the
master so that a master crash is not silent.

**`BlockedIndefinitelyOnSTM`** is the exception GHC's runtime throws at a thread that is
blocked in an STM transaction on `TVar`s that no live thread can reach. The runtime finds such
threads during a major garbage collection: anything not reachable from a root (a running
thread, a thread waiting on a timer or on I/O, a stable pointer) is, by construction, never
going to be woken. It is not a timeout; an idle-but-reachable thread is never flagged.

### Why the two combine badly here

The master loop is blocked on a mailbox nobody writes to. Its mailbox is reachable only through
the `Master` record. Whether a caller keeps that record alive is an accident of what the
caller does with the `AppHandle`. A metrics server closure keeps it alive; a bare `waitApp`
does not, because `waitApp` only needs `appHandle.processors`. In the second case the first
major collection resurrects the loop with `BlockedIndefinitelyOnSTM`, and the link turns that
into a crash of the caller — typically the program's main thread.

### Evidence

From the consumer side, `mls-service-v2`'s single-processor subcommands all fail within two to
three seconds with the exception above, while its four-processor `run-all-queues` runs for
days; the sole structural difference is that the latter hands `getAppMaster handle` to a Warp
application. The full account is in
`mori://tan/mls-service-v2/plans/101-find-and-fix-the-queue-worker-s-per-message-memory-retention`.
From this repository's side, the `RunnerSpec` comment quoted under Surprises & Discoveries
describes the same exception as a flake.

### ADRs

This repository has no `docs/adr/` directory, so there is no ADR to cite. The durable design
context lives in `docs/plans/25-pre-1-0-public-api-cleanup.md` (what is internal and unstable)
and `docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md` (why children are
linked conditionally on `propagateFailures`). Neither needs changing; this plan removes an
actor those plans left in place, not a decision they made.


## Plan of Work

### Milestone 1: A regression test that fails today

The scope is one test in `shibuya-core/test/Shibuya/App/LifecycleSpec.hs` that reproduces the
consumer's failure shape inside the test suite: start an app whose adapter is idle in the way a
real queue adapter is idle (sleeping in `threadDelay` between polls, which keeps the ingester a
garbage-collection root), call `waitApp` without holding the handle anywhere else, force several
major collections, and assert that the waiting thread is still waiting rather than dead.

The subtlety is not holding the handle. If the test keeps `app` in scope for a later `stopApp`,
GHC keeps the `Master` reachable and the test passes for the wrong reason. The test therefore
takes a weak pointer to the handle before waiting and uses that, after the timeout, to stop the
app for cleanup. A weak pointer does not keep its target alive, so the test sees exactly what a
bare `waitApp` caller sees.

At the end of this milestone the test exists, is wired into the suite, and fails on the current
code with `ExceptionInLinkedThread`. That failure is the milestone's acceptance.

### Milestone 2: Remove the master loop

The scope is `Master.hs` and nothing else in `src/`. `MasterMessage`, `handleMessage`,
`masterLoop`, the `async`/`link` pair in `startMaster`, the `cancel master.handle` in
`stopMaster`, and the `handle` and `inbox` fields of `Master` all go. `Master` becomes a record
with a single `state` field. `registerProcessor` and `unregisterProcessor` are already direct
`TVar` writes and do not change. The imports from `Control.Concurrent.NQE.Process` shrink to
nothing (the supervisor comes from `Control.Concurrent.NQE.Supervisor`), and the `UnliftIO`
import shrinks to `cancel`.

Nothing outside `Master.hs` refers to the removed names: `Supervised.hs` uses only
`master.state.*`, `App.hs` uses `startMaster`, `stopMaster`, and the metrics readers, and the
benchmarks import only `startMaster` and `stopMaster`. `cabal build all` is the check.

At the end of this milestone the Milestone 1 test passes, the whole suite passes, and the
`RunnerSpec` comments no longer claim the master deadlocks.

### Milestone 3: Documentation

Four documents still describe the master as an actor with a mailbox: `CLAUDE.md` ("NQE-based
supervision (Master, Supervisor, Inbox)" and the `runApp → Master → …` diagram),
`docs/MULTI_QUEUE_DESIGN.md` ("`Master` - Coordinator process managing child processors"),
`docs/HIGH_LEVEL_ARCHITECTURE.md` (a `MasterMessage` sketch and `query GetAllMetrics
masterProcess`), and `docs/architecture/RUNNER_BUG_FIXES.md` (Bug 1, whose "only cancelled the
master message loop" history stays true but whose present-tense description should say the
loop no longer exists). `docs/plans/PROCESSOR_PAUSE_DESIGN.md` proposes extending
`MasterMessage` for pause/resume; add a note that the actor is gone and that design would
reintroduce one deliberately. The older plans are history and are not edited.

### Milestone 4: Changelog and release

Add a `0.9.1.0` section to `CHANGELOG.md` under both packages (`shibuya-metrics` bumps to track
`shibuya-core`, as `0.9.0.1` did) and cut the release with the repository's release skill
(`agents/skills/release/SKILL.md`), which decides the bump level from the diff and publishes
`shibuya-core` before `shibuya-metrics`.

### Milestone 5: Consumer follow-up

In `mls-service-v2`, bump the `shibuya-core` and `shibuya-metrics` pins to the new release via
its `just update-cabal-freeze` (which regenerates its freeze file and nix overlay together),
and confirm `cabal run exe:mls-service-v2 -- queue-worker run-area-details-cache` runs past the
point where it crashes today. `shibuya-pgmq-adapter` does not need a release for this: it
depends on `shibuya-core ^>=0.9`, which `0.9.1.0` satisfies.


## Concrete Steps

All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

### Milestone 1 steps

Add to `shibuya-core/test/Shibuya/App/LifecycleSpec.hs`, inside the `describe "Shibuya.App
lifecycle"` block. The spec already defines `infiniteAdapter` (an adapter that sleeps 5 ms in
`threadDelay` between messages), `runAppOrFail`, and `alwaysAckOk`; the new test needs an
adapter that is idle for the whole run, so give it a longer sleep:

```haskell
  it "an idle app whose handle is only used by waitApp survives major collections" $ do
    -- Reproduces the shape of a bare `runApp` then `waitApp` caller: nothing but the
    -- waiting transaction refers to the handle, the adapter is idle in threadDelay
    -- (a GC root, like a queue adapter between polls), and several major collections
    -- run while we wait. Before the master loop was removed, the first collection
    -- found the linked master blocked on a mailbox nobody could reach and killed
    -- this thread with ExceptionInLinkedThread.
    weakRef <- newIORef Nothing
    outcome <-
      UIO.try @_ @SomeException $
        UIO.timeout 2_000_000 $
          runEff $
            runTracingNoop $ do
              app <- runAppOrFail IgnoreFailures 10 [(ProcessorId "idle", mkProcessor idleAdapter alwaysAckOk)]
              weak <- liftIO $ mkWeakPtr app Nothing
              liftIO $ writeIORef weakRef (Just weak)
              _ <- liftIO $ forkIO $ replicateM_ 5 (threadDelay 100_000 >> performMajorGC)
              waitApp app

    -- Cleanup through the weak pointer, so the test itself never held the handle.
    liftIO (readIORef weakRef) >>= \case
      Just weak -> liftIO (deRefWeak weak) >>= mapM_ (\app -> runEff (runTracingNoop (stopApp app)))
      Nothing -> pure ()

    case outcome of
      Right Nothing -> pure () -- timed out while still waiting: the app is alive
      Right (Just ()) -> expectationFailure "waitApp returned; the idle processor should not finish"
      Left e -> expectationFailure ("waitApp died: " <> show e)
```

with the helper next to `infiniteAdapter`:

```haskell
idleAdapter :: (IOE :> es) => Adapter es String
idleAdapter =
  Adapter
    { adapterName = "test:idle",
      source = Stream.unfoldrM step (1 :: Int),
      shutdown = pure ()
    }
  where
    step n = do
      liftIO $ threadDelay 60_000_000
      msg <- createTestMessage n
      pure (Just (msg, n + 1))
```

and the imports the snippet needs: `Control.Concurrent (forkIO)`, `Control.Exception
(SomeException)`, `Control.Monad (replicateM_)`, `Data.IORef`, `System.Mem (performMajorGC)`,
`System.Mem.Weak (deRefWeak, mkWeakPtr)`, and `stopApp` from `Shibuya.App`. If the module
does not already enable `LambdaCase`, add the pragma.

Run it:

```bash
cabal test shibuya-core-test --test-options='-m "survives major collections"'
```

Expected on the current code — the failure that proves the test is real:

```text
  1) Shibuya.App lifecycle an idle app whose handle is only used by waitApp survives major collections
       waitApp died: ExceptionInLinkedThread (ThreadId ...) thread blocked indefinitely in an STM transaction
```

If instead the test passes before any fix, the handle is still reachable: check that nothing
after `waitApp app` mentions `app` directly and that the weak pointer is created *before*
`waitApp`. GHC's `-O` can also keep `app` alive on the stack; if that happens, move the
`waitApp` call into a helper that takes only `appHandle.processors`-derived data, or run the
test with `-O0` for the test suite.

### Milestone 2 steps

Edit `shibuya-core/src/Shibuya/Internal/Runner/Master.hs`. The export list loses
`MasterMessage (..)`. The data declarations become:

```haskell
data MasterState = MasterState
  { metrics :: !(TVar (Map ProcessorId MetricsHandle)),
    supervisor :: !Supervisor,
    propagateFailures :: !Bool
  }
  deriving (Generic)

-- | The master owns the NQE supervisor and the processor metrics registry.
-- It is not an actor: nothing runs on its behalf, so there is nothing that
-- can be blocked on a mailbox and nothing to link. (An earlier version ran a
-- message loop here; with no senders it was flagged deadlocked by the RTS
-- whenever the caller did not keep this record reachable, and the link
-- turned that into a crash of the caller.)
newtype Master = Master
  { state :: MasterState
  }
  deriving (Generic)
```

`startMaster` becomes:

```haskell
startMaster :: (IOE :> es) => Strategy -> Eff es Master
startMaster strategy = liftIO $ do
  sup <- Supervisor.supervisor strategy
  metricsMapVar <- newTVarIO Map.empty
  let propagate = case strategy of
        KillAll -> True
        IgnoreGraceful -> True
        IgnoreAll -> False
        Notify _ -> False
  pure Master {state = MasterState metricsMapVar sup propagate}
```

and `stopMaster` cancels only the supervisor:

```haskell
stopMaster :: (IOE :> es) => Master -> Eff es ()
stopMaster master = liftIO $ cancel (getProcessAsync master.state.supervisor)
```

Delete `MasterMessage`, `masterLoop`, and `handleMessage`. Drop the now-unused imports
(`Inbox`, `Listen`, `newInbox`, `receive` from `Control.Concurrent.NQE.Process`; `forever`;
`async` and `link` from `UnliftIO`). Keep `Process (..)` only if `getProcessAsync` comes from
it — it does; keep that import.

Then in `shibuya-core/test/Shibuya/RunnerSpec.hs`, replace the two comment blocks that justify
`stopApp` with "Stop the app so its supervisor and children do not outlive the test." The
calls stay.

Build and test everything:

```bash
cabal build all
cabal test shibuya-core-test
```

Expected: the build succeeds with no new warnings (the package builds with `-Wall`; an unused
import left behind will fail `nix flake check` later, so fix any here), and the suite reports
all tests passing including the new one. Format before committing, as `CLAUDE.md` requires:

```bash
nix fmt
```

### Milestone 3 steps

Edit the four documents named under Plan of Work. Keep each change to the sentences that
describe the master as a process with a mailbox; do not rewrite the documents.

### Milestone 4 steps

Add to `CHANGELOG.md` above the `0.9.0.1` section:

```markdown
## 0.9.1.0 — <date>

### Bug Fixes

- `shibuya-core`: a program that called `runApp` and then `waitApp` without keeping the
  `AppHandle` reachable elsewhere died at its first major garbage collection with
  `ExceptionInLinkedThread ... thread blocked indefinitely in an STM transaction`. The
  master started an actor loop that blocked forever on a mailbox nothing ever sent to, and
  linked it to the caller; when the caller did not keep the master reachable the RTS
  correctly flagged the loop as deadlocked and the link killed the caller. The loop, its
  mailbox, and the `MasterMessage` protocol are removed. `Master` (still opaque in
  `Shibuya.App`) now holds only the supervisor and the metrics registry;
  `Shibuya.Internal.Runner.Master` no longer exports `MasterMessage`. A regression test
  runs an idle app through several major collections under a bare `waitApp`.
- `shibuya-metrics`: version bumped to track `shibuya-core`; no changes.
```

Then run the release skill from the repository root and follow it; it determines the bump from
the diff, tags `v0.9.1.0`, and publishes `shibuya-core` before `shibuya-metrics`.

### Milestone 5 steps

In `/Users/shinzui/Keikaku/work/microtan/mls-service-v2-master`, once `0.9.1.0` is on Hackage
or the local index:

```bash
just update-cabal-freeze
cabal build exe:mls-service-v2
timeout 40 cabal run -v0 exe:mls-service-v2 -- queue-worker run-area-details-cache; echo "exit=$?"
```

Expected `exit=124` — the subcommand ran until `timeout` stopped it, instead of `exit=1` after
about two seconds with the linked-thread exception. Commit `cabal.project.freeze` and
`nix/haskell-overlay.nix` together there, as that repository's `CLAUDE.md` requires.


## Validation and Acceptance

Milestone 1 is accepted when the new test fails on the current code with
`ExceptionInLinkedThread` in its message, as shown above. A test that passes before the fix
proves nothing and must be fixed first.

Milestone 2 is accepted when `cabal build all` succeeds without new warnings and `cabal test
shibuya-core-test` passes with the new test included, run at least three times to confirm the
former flake in `RunnerSpec` does not reappear.

Milestone 3 is accepted when `grep -rn -i 'master loop\|MasterMessage\|masterProcess'
CLAUDE.md docs/MULTI_QUEUE_DESIGN.md docs/HIGH_LEVEL_ARCHITECTURE.md
docs/architecture/RUNNER_BUG_FIXES.md` returns only historical descriptions that say the loop
was removed, and `nix flake check` passes.

Milestone 4 is accepted when the tag exists and both packages are published at the same
version.

Milestone 5 is accepted when, in `mls-service-v2`, `queue-worker run-area-details-cache` runs
until killed by `timeout` rather than exiting on its own.


## Idempotence and Recovery

Every step is a source edit under version control; rerunning a step is harmless and rolling
back is `git revert`. The Milestone 1 test leaks one idle app for at most the test's lifetime if
its cleanup path fails; that cannot affect other tests because the processor never processes
anything. The release in Milestone 4 is the only step with an external side effect, and the
release skill owns its retry semantics.


## Interfaces and Dependencies

No dependency changes. `nqe ^>=0.6` stays; the supervisor is still created with
`Control.Concurrent.NQE.Supervisor.supervisor` and stopped by cancelling
`getProcessAsync master.state.supervisor`.

Signatures that must hold at the end of Milestone 2, all in
`Shibuya.Internal.Runner.Master`:

```haskell
data MasterState = MasterState
  { metrics :: !(TVar (Map ProcessorId MetricsHandle)),
    supervisor :: !Supervisor,
    propagateFailures :: !Bool
  }

newtype Master = Master {state :: MasterState}

startMaster :: (IOE :> es) => Strategy -> Eff es Master
stopMaster :: (IOE :> es) => Master -> Eff es ()
getAllMetrics :: (IOE :> es) => Master -> Eff es MetricsMap
getAllMetricsIO :: Master -> IO MetricsMap
getProcessorMetrics :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
registerProcessor :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Eff es ()
unregisterProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
```

`MasterMessage` no longer exists. `Shibuya.App`'s exports — `Master` (abstract),
`getAppMaster`, `getAllMetrics`, `getAllMetricsIO`, `getProcessorMetrics`,
`getProcessorMetricsIO`, `runApp`, `waitApp`, `stopApp`, `stopAppGracefully` — are unchanged
in name and type.
