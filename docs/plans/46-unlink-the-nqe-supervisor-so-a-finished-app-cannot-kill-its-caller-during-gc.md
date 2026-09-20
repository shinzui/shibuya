---
id: 46
slug: unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc
title: "Unlink the NQE supervisor so a finished app cannot kill its caller during GC"
kind: exec-plan
created_at: 2026-09-20T04:36:50Z
intention: "intention_01m2ycc3fxedxtw5339e0efzy1"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-20T04:36:50Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T05:10:35Z
      mode: "implement"
      note: "Implement Milestones 1-3 and prepare the patch release for owner approval"
---

# Unlink the NQE supervisor so a finished app cannot kill its caller during GC

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Shibuya 0.9.0.2 fixed a crash in which a healthy, idle application died during garbage
collection. An independent review of that fix, recorded in
`docs/reviews/REV-16-childless-supervisor-gc-residual.md`, found that the same crash still
happens in a second situation, and found a related defect with the same cause. Both are
reproduced on the released library. This plan removes the cause and ships it as a patch.

After this change two things are true that are not true today. First, a program whose
queue processors have all finished, halted or failed can drop its application handle and
keep running: today the next major garbage collection kills the thread that called `runApp`
with `ExceptionInLinkedThread ... thread blocked indefinitely in an STM transaction`.
A service that runs a finite job and then carries on, or a service running under
`IgnoreFailures` whose only processor's source has died, is exposed. Second, under
`StopAllOnFailure` one processor failure reaches the caller exactly once: today it is
delivered twice, and the second copy arrives at an arbitrary later moment, so a caller that
handles the first failure and begins cleaning up can be killed by the second.

You can see it working with two commands. The new process-isolated test prints three `PASS`
lines where it prints three `FAIL` lines today, and the lifecycle suite gains a case asserting
a single delivery:

```bash
cabal test shibuya-core:shibuya-core-gc-finished-test --test-show-details=direct
cabal test shibuya-core --test-show-details=failures
```

This plan is deliberately standalone. The project owner judged the defect urgent and asked
that it not wait for, or be coordinated by,
`docs/masterplans/6-comprehensive-lifecycle-remediation-and-release-assurance.md`. It follows
the precedent of `docs/plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md`,
which shipped its fix as an independent patch release.


## Progress

- [x] (2026-09-20 UTC) Reproduce both defects against the 0.9.0.2 library with diagnostic probes and record them as REV-16.
- [x] (2026-09-20 UTC) Prototype the unlinked supervisor in an isolated worktree: the probe survives 18 of 18 runs and both existing core suites pass with 212 examples and zero failures.
- [x] (2026-09-20 UTC) Confirm that the exact regression source in Milestone 1 compiles under `-Wall` and fails on all three scenarios against the unfixed library.
- [x] (2026-09-20 UTC) Milestone 1: Commit the process-isolated finished-application regression and the single-delivery lifecycle test, both failing for the right reason. Observed on the unfixed library: three `FAIL` lines from `shibuya-core-gc-finished-test`, `expected: Just 1 but got: Just 2` as the only failure among 213 Hspec examples, and `shibuya-core-gc-test` still passing.
- [ ] Milestone 2: Start the supervisor without NQE's unconditional link; both new tests and every existing test pass.
- [ ] Milestone 3: Correct the architecture documents, amend ADR 0001, and point the audit records at the fix.
- [ ] Milestone 4: Prepare and validate the patch release; publish only after the owner approves the version and changelog.


## Surprises & Discoveries

**The supervisor is the same kind of thread the previous fix removed.** `startMaster` calls
NQE's `Supervisor.supervisor`, which is `process (supervisorProcess strategy)`. NQE's
`process` creates a mailbox, runs the loop in a new thread, and links that thread to its
creator. The supervisor's loop waits for a mailbox message or for a child to finish, and its
child wait begins with `when (null as) retry`. With no children the mailbox is therefore the
only thing that can wake it, and the mailbox is reachable only through the application
handle. The 0.9.0.2 regression could not see this because its single idle processor keeps the
supervisor reachable for the whole observation.

Observed on the 0.9.0.2 library, GHC 9.12.4, `-O1`, `-threaded`, `+RTS -N2`, three runs per
cell with identical results, using `scripts/audit/ChildlessSupervisorProbe.hs`. `drop` discards
the handle after `waitApp`, `stop` calls `stopApp` first, and `retain` keeps the handle alive
past the collections; `ignore` and `stopall` are the two supervision strategies:

```text
RESULT drop/ignore: CALLER KILLED: ExceptionInLinkedThread (ThreadId 6) thread blocked indefinitely in an STM transaction
RESULT stop/ignore: caller survived
RESULT retain/ignore: caller survived
RESULT drop/stopall: CALLER KILLED: ExceptionInLinkedThread (ThreadId 6) thread blocked indefinitely in an STM transaction
RESULT stop/stopall: caller survived
RESULT retain/stopall: caller survived
```

**One failure is delivered twice, and the second copy can be fatal.**
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` already links every processor to the
caller when the strategy propagates failures. NQE's supervisor, on a child failure under that
strategy, stops the siblings and rethrows the child's exception, so its own link fires as
well. `scripts/audit/LinkedFailureDeliveryProbe.hs` starts one processor whose source throws,
keeps the handle alive so that garbage collection plays no part, and counts what the calling
thread receives. Three runs on the 0.9.0.2 library:

```text
probe-dd: Uncaught exception ghc-internal:GHC.Internal.IO.Exception.SomeAsyncException:

ExceptionInLinkedThread (ThreadId 8) user error (boom)
probe-dd: Uncaught exception ghc-internal:GHC.Internal.IO.Exception.SomeAsyncException:

ExceptionInLinkedThread (ThreadId 6) user error (boom)
RESULT deliveries=2
  ExceptionInLinkedThread (ThreadId 8) user error (boom)
  ExceptionInLinkedThread (ThreadId 6) user error (boom)
```

Thread 8 is the processor and thread 6 is the supervisor. In two of the three runs the second
exception arrived between the probe's handlers and ended the process, which is exactly what
would happen to an application that caught the first one and started shutting down.

**The prototype fixes the first defect without disturbing propagation.** With the supervisor
started unlinked, as in the diff under Plan of Work, the same probe reported `caller survived`
in all 18 runs across the six cells, and `cabal test shibuya-core --offline` passed both
existing suites, including "failure under StopAllOnFailure kills siblings and propagates".
The single-delivery result after the fix follows from the construction, because the child's
link is then the only one left, but it was not measured in the prototype; Milestone 2 measures it.

**An offline build in a fresh worktree needs the git dependency copied in.** `cabal.project`
takes hs-opentelemetry from a git repository, which Cabal checks out under
`dist-newstyle/src/`. A new worktree has no such checkout and `--offline` cannot clone it;
the build stops with `getDirectoryContents:openDirStream: does not exist`. Copying the main
tree's `dist-newstyle/src` directory, and `cabal.project.local` if present, into the worktree
before building resolves it.


## Decision Log

- Decision: Keep this plan outside master plan 6 and give it no dependency on that initiative.
  Rationale: The project owner called the defect urgent and asked for it to be handled
  independently. It is a small, self-contained change to one function with its own regression,
  the same shape as the 0.9.0.2 fix, and it should not queue behind an evidence ledger and a
  four-milestone core plan.
  Date: 2026-09-19

- Decision: Fix the defect by starting the supervisor without NQE's link, assembling the
  `Process` value from `newMailbox` and an unlinked `async`.
  Rationale: The link is the mechanism of both defects and delivers nothing the per-processor
  links do not already deliver. Without it, a supervisor that has no children and that nobody
  can reach is simply collected. Rejected alternatives: keeping the link but filtering out the
  indefinitely-blocked exception would leave the double delivery in place, would hide a genuine
  supervisor deadlock, and needs a new direct dependency on `async`; retaining the handle in a
  global root, or reintroducing an idle actor, contradicts `docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md`;
  making `waitApp` stop the master implicitly would change what `waitApp` means and would not
  help a caller who never calls it; replacing NQE is far larger than the defect.
  Date: 2026-09-19

- Decision: Put the finished-application regression in its own Cabal test suite rather than
  adding arguments to the existing GC test.
  Rationale: A Cabal test suite receives no arguments unless the user passes `--test-options`,
  so an argument-driven scenario would not run under the plain `cabal test shibuya-core` that
  the release gate uses. A separate stanza runs by default and leaves the proven 0.9.0.2
  regression untouched.
  Date: 2026-09-19

- Decision: Run the three scenarios in one process, each on its own thread.
  Rationale: The link targets whichever thread calls `runApp`, so a fresh thread per scenario
  isolates the failures from each other and from the test's main thread while keeping one fast
  executable. This was verified to reproduce the failure for all three before this plan was written.
  Date: 2026-09-19

- Decision: Release as a Haskell Package Versioning Policy patch and choose the number at
  release time from the registry, expecting 0.9.0.3.
  Rationale: No public signature changes; the only source change is inside
  `Shibuya.Internal.Runner.Master`, whose header disclaims versioning guarantees, and the
  observable change is a corrected failure mode. The expectation is recorded because
  `docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`
  provisionally claimed 0.9.0.3, exactly as it once provisionally claimed the number the
  0.9.0.2 fix took; Milestone 4 repeats that precedent and moves the provisional claim along.
  Date: 2026-09-19

- Decision: No downstream consumer milestone.
  Rationale: The known consumer runs processors that never finish, so it is not exposed unless
  all of them die; it can take the patch at its normal cadence. Registration-service-v2
  remains out of scope as before.
  Date: 2026-09-19


## Outcomes & Retrospective

Nothing is released yet. The defects are reproduced, the fix is prototyped, and the regression
source is proven to fail on the current library. The production change, its committed tests,
documentation and release remain. Before marking the plan complete, distill the durable lesson
into `docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` as Milestone 3 describes.


## Context and Orientation

Shibuya is a Haskell library for supervised queue processing. An application calls `runApp`
in `shibuya-core/src/Shibuya/App.hs` with a list of queue processors and gets back an
`AppHandle`. `waitApp` blocks until every processor is done. `stopApp` and
`stopAppGracefully` shut the application down; the last thing they do is call `stopMaster`.
A supervision strategy chooses what one processor's failure does to the rest:
`IgnoreFailures` isolates it, and `StopAllOnFailure` stops the siblings and reports the
failure to the caller.

`shibuya-core/src/Shibuya/Internal/Runner/Master.hs` defines `Master`, a small handle that
holds the metrics registry, a flag `propagateFailures` derived from the strategy, and a
supervisor from the NQE library. NQE is a small actor library: a *process* is a thread with a
*mailbox*, a queue other threads send messages to, and a *supervisor* is a process that starts
child threads, watches them, and applies a strategy when one stops. `startMaster` creates the
supervisor; `stopMaster` cancels its thread, which in turn cancels all children.
`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` starts each processor as a child with
`addChild`, and, when `propagateFailures` is set, additionally *links* that child to the
calling thread.

Several terms matter here. An *async* is a handle to a thread started with the `async`
function, through which the thread's result can be awaited or the thread cancelled. To *link*
an async is to arrange that, if its thread dies with an exception other than cancellation, the
linking thread is sent `ExceptionInLinkedThread` wrapping that exception; it is an
asynchronous exception, meaning it interrupts the receiving thread wherever it happens to be.
STM, software transactional memory, is GHC's mechanism for atomically reading and writing
shared transactional variables; a thread whose transaction cannot proceed sleeps until one of
the variables it read is changed. GHC's garbage collector treats a sleeping thread as
*reachable* only if something live still refers to a variable that could wake it. During a
*major collection*, the full collection of the heap, a thread found to be unreachable is woken
with `BlockedIndefinitelyOnSTM`, the runtime's way of saying the wait can never end.

The two NQE facts this plan depends on come from its 0.6.6 source, which is not registered in
Mori; it is in the local Cabal package cache at
`~/.cabal/packages/hackage.haskell.org/nqe/0.6.6/nqe-0.6.6.tar.gz` and on Hackage.
`Control.Concurrent.NQE.Process` has no export list, so everything in it is importable, and
contains:

```haskell
process :: MonadUnliftIO m => (Inbox msg -> m ()) -> m (Process msg)
process p = do
    (i, m) <- newMailbox
    a <- async $ p i
    link a
    return (Process a m)
```

`Control.Concurrent.NQE.Supervisor` exports `supervisorProcess` and defines
`supervisor strat = process (supervisorProcess strat)`. Its loop and child wait are:

```haskell
loop state = do
  e <- atomically $ Right <$> receiveSTM i <|> Left <$> waitForChild state
  ...

waitForChild state = do
  as <- readTVar state
  when (null as) retry
  waitAnyCatchSTM as
```

NQE removes a child from that list whenever it finishes, under every strategy. So once all
processors are done, the supervisor can be woken only through its mailbox, and the mailbox is
held only by the `Process` value inside `Master` inside the `AppHandle`. If the program lets
the handle go and keeps running, the next major collection raises `BlockedIndefinitelyOnSTM`
in the supervisor and the link forwards it to the thread that called `runApp`. Under a
propagating strategy the same link also re-delivers a processor failure that the
per-processor link has already delivered.

The relevant local decision record is
`docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md`. It records the 0.9.0.2
fix: remove a linked actor whose wait source has no remaining sender, never keep one alive
with an artificial root, treat reachability-sensitive liveness as a release property, and test
it in a separate process that retains nothing but the public action under test. It also states
that `Master` contains "the real NQE supervisor" and that `stopMaster` cancels it. This plan
keeps all of that and extends the principle to the supervisor thread; Milestone 3 amends the
record. There is no other ADR in the repository, and the corpus is a plain filesystem
convention with no OKF profile, so keep its existing plain Markdown format.

The existing regression is `shibuya-core/test-gc/Main.hs`, registered in
`shibuya-core/shibuya-core.cabal` as the test suite `shibuya-core-gc-test`. It runs an idle
processor that never finishes, so it exercises a supervisor that has a child. The ordinary
suite is `shibuya-core-test`; its lifecycle cases are in
`shibuya-core/test/Shibuya/App/LifecycleSpec.hs`, which already has the helpers
`runAppOrFail` and `failingAfterAdapter` and the case "failure under StopAllOnFailure kills
siblings and propagates". `cabal test shibuya-core` runs every suite in the package. `CLAUDE.md`
and step 4 of `agents/skills/release/SKILL.md` name the two suites explicitly.
`docs/architecture/CONCURRENCY.md` shows `Supervisor.supervisor` in a snippet and has a table
row saying that linking propagates exceptions to the parent.

Master plan 6 refers to this plan as an external prerequisite, in the way it refers to plans
34 and 35. Its core child,
`docs/plans/38-make-core-processor-ownership-and-termination-exception-safe.md`, later adds a
retained lifecycle snapshot to `Master.hs` and must keep this plan's tests green. Nothing here
waits for it.


## Plan of Work

### Milestone 1: Regressions that fail first

At the end of this milestone the repository contains two tests that fail on the unfixed
library for the documented reason. They stay visibly failing until Milestone 2; do not mark
them pending, weaken their assertions, or retain the handle to make them pass.

Create `shibuya-core/test-gc/Finished.hs` with exactly this content. It has been compiled
under `-Wall` and run against the 0.9.0.2 library, where all three scenarios fail as shown in
Concrete Steps. The third scenario is the one most likely in production: a source fails under
`IgnoreFailures` and the service carries on.

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- This probe owns its process for the same reason as Main.hs: retaining an
-- AppHandle for cleanup would hide the bug. It covers the state Main.hs cannot:
-- an application whose processors have all finished, so the supervisor has no
-- children, while the thread that called runApp keeps running.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (displayException, throwIO)
import Control.Monad (forM, replicateM_, unless)
import Effectful (liftIO, runEff)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( AppConfig (..),
    ProcessorId (..),
    SupervisionStrategy (..),
    defaultAppConfig,
    mkProcessor,
    runApp,
    waitApp,
  )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Exit (die, exitFailure)
import System.Mem (performMajorGC)
import UnliftIO qualified as UIO

main :: IO ()
main = do
  results <- forM scenarios $ \(name, strat, sourceFails) -> do
    -- Each scenario gets its own thread: the supervisor links to whichever
    -- thread calls runApp, and that is the thread a regression kills.
    outcome <- UIO.timeout 10_000_000 $ UIO.withAsync (caller strat sourceFails) UIO.waitCatch
    case outcome of
      Nothing -> False <$ putStrLn ("FAIL [" <> name <> "]: the observation did not finish within ten seconds")
      Just (Left err) -> False <$ putStrLn ("FAIL [" <> name <> "]: caller died after its application finished: " <> displayException err)
      Just (Right ()) -> True <$ putStrLn ("PASS [" <> name <> "]: caller survives major collections after its application finished")
  unless (and results) exitFailure
  where
    scenarios =
      [ ("finite source, IgnoreFailures", IgnoreFailures, False),
        ("finite source, StopAllOnFailure", StopAllOnFailure, False),
        ("failed source, IgnoreFailures", IgnoreFailures, True)
      ]

caller :: SupervisionStrategy -> Bool -> IO ()
caller strat sourceFails = do
  runEff $ runTracingNoop $ do
    let adapter =
          Adapter
            { adapterName = "gc-regression:finished",
              source =
                if sourceFails
                  then Stream.fromEffect (liftIO (throwIO (userError "the source failed on purpose")))
                  else Stream.nil,
              shutdown = pure ()
            }
    result <-
      runApp
        defaultAppConfig {strategy = strat}
        [(ProcessorId "finished", mkProcessor adapter (\_ -> pure AckOk))]
    case result of
      Left err -> liftIO $ die ("runApp failed: " <> show err)
      Right app -> waitApp app
  -- The handle is now out of scope. Deliberately no stopApp and no retained
  -- reference: every processor has finished and this thread simply carries on.
  replicateM_ 5 $ do
    threadDelay 100_000
    performMajorGC
  -- Leave time for a linked exception from the last collection to arrive.
  threadDelay 200_000
```

Register it in `shibuya-core/shibuya-core.cabal` directly after the `shibuya-core-gc-test`
stanza, copying that stanza and changing only the name and `main-is`:

```cabal
test-suite shibuya-core-gc-finished-test
  import: warnings
  default-language: GHC2024
  type: exitcode-stdio-1.0
  hs-source-dirs: test-gc
  main-is: Finished.hs
  ghc-options:
    -threaded
    -rtsopts
    -with-rtsopts=-N2

  build-depends:
    base ^>=4.21.0.0,
    effectful,
    shibuya-core,
    streamly-core,
    unliftio,
```

Two suites sharing `test-gc` is fine because each names its own `main-is` and neither lists
other modules. Keep the normal optimization profile; do not add flags to coax a result.

Then add a case to `shibuya-core/test/Shibuya/App/LifecycleSpec.hs`, next to "failure under
StopAllOnFailure kills siblings and propagates", named "StopAllOnFailure delivers one
processor failure to the caller exactly once". Counting asynchronous exceptions reliably needs
care, because one that arrives between two handlers escapes both, as the probe output above
shows. Run the scenario on its own thread with `UIO.withAsync` and `UIO.wait`, so the linked
exceptions target that thread and not the test runner. Inside it, take `mask` and do all
waiting inside `restore`: call `runAppOrFail StopAllOnFailure 10` with one processor built
from `failingAfterAdapter 0`, wrapped in `try` and `restore`, and count a `Left` as the first
delivery; then loop on `try (restore (threadDelay 300_000))`, adding one for every `Left` and
stopping at the first window that ends with `Right ()`. With exceptions masked everywhere
except inside those `restore` calls, none can land between iterations, so the count is exact.
Keep the application handle alive until after the loop and then call `stopApp` on it, so that
garbage collection cannot contribute. Assert the count equals one. On the unfixed library it
is two.

Acceptance is that `cabal test shibuya-core` fails, with the new GC suite printing three `FAIL`
lines that name `ExceptionInLinkedThread` and "blocked indefinitely", the new lifecycle case
reporting two where one was expected, and every other test passing. A compile error, a
timeout, or a failure in any other test is not acceptance.

### Milestone 2: Start the supervisor unlinked

Change only `startMaster` in `shibuya-core/src/Shibuya/Internal/Runner/Master.hs`. This is the
prototyped diff:

```diff
diff --git a/shibuya-core/src/Shibuya/Internal/Runner/Master.hs b/shibuya-core/src/Shibuya/Internal/Runner/Master.hs
index c785ae2..2391ff6 100644
--- a/shibuya-core/src/Shibuya/Internal/Runner/Master.hs
+++ b/shibuya-core/src/Shibuya/Internal/Runner/Master.hs
@@ -30,7 +30,7 @@ module Shibuya.Internal.Runner.Master
   )
 where
 
-import Control.Concurrent.NQE.Process (Process (..))
+import Control.Concurrent.NQE.Process (Process (..), newMailbox)
 import Control.Concurrent.NQE.Supervisor (Strategy (..), Supervisor)
 import Control.Concurrent.NQE.Supervisor qualified as Supervisor
 import Control.Concurrent.STM
@@ -51,7 +51,7 @@ import Shibuya.Core.Metrics
     sampleMetrics,
   )
 import Shibuya.Prelude
-import UnliftIO (cancel)
+import UnliftIO (async, cancel)
 
 -- | Master state held in TVars.
 data MasterState = MasterState
@@ -78,8 +78,10 @@ newtype Master = Master
 -- The caller is responsible for calling stopMaster when done.
 startMaster :: (IOE :> es) => Strategy -> Eff es Master
 startMaster strategy = liftIO $ do
-  -- Create supervisor
-  sup <- Supervisor.supervisor strategy
+  -- Run the NQE supervisor loop without NQE's unconditional link to this thread.
+  (inbox, mailbox) <- newMailbox
+  supAsync <- async (Supervisor.supervisorProcess strategy inbox)
+  let sup = Process supAsync mailbox
 
   metricsMapVar <- newTVarIO Map.empty
   let propagate = case strategy of
```

`Process`, `newMailbox` and `supervisorProcess` are all existing NQE exports; no dependency or
bound changes. `stopMaster` is untouched: it cancels the same async, and the supervisor's
`finally` still cancels every child. `MasterState`, the metrics functions and the
`propagateFailures` mapping are untouched, and so is every link installed in `Supervised.hs`.
Extend the Haddock on `startMaster` to say why the supervisor is deliberately not linked: its
only wake source when it has no children is a mailbox reachable solely through the handle, so a
link would turn a dropped handle into an exception in the caller, and processor failures
already reach the caller through the per-processor links.

Acceptance is that both new tests pass, the 0.9.0.2 regression `shibuya-core-gc-test` still
passes, and the whole ordinary suite passes, in particular the existing propagation, isolation,
halt and shutdown cases. Run the new GC suite three times in a row and record the results, as
the previous fix did. Then prove the tests are effective: in an isolated worktree of the
Milestone 1 commit, confirm they fail, without touching the working tree.

### Milestone 3: Documents and records

In `CLAUDE.md` change the comment on the `cabal test shibuya-core` line to name all three
suites. In step 4 of `agents/skills/release/SKILL.md` name `shibuya-core-gc-finished-test`
alongside the other two and say what it guards. In `docs/architecture/CONCURRENCY.md` replace
the `Supervisor.supervisor` snippet with the unlinked construction and qualify the process
linking row: processors are linked to the caller when the strategy propagates failures, and
the supervisor thread itself is not linked. Check `docs/HIGH_LEVEL_ARCHITECTURE.md` and
`docs/architecture/RUNNER_BUG_FIXES.md` for a present-tense claim that the supervisor is
linked, correct any that exist, and leave explicitly historical passages alone.

Amend `docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` in its existing
plain Markdown format. Add to the Decision that the rule covers the supervisor too: never link
a thread to a caller when the only thing that can wake it is reachable solely through a handle
the caller is free to drop, and deliver processor failures through per-processor links only, so
that one failure produces one exception. Add to Consequences that the supervisor runs unlinked
and that a supervisor with no children and no reachable handle is collected silently. Add to
Evidence this plan, REV-16 and the two new tests. Correct the sentence implying the 0.9.0.2
regression alone covers this class of bug: it covers a supervisor with a live child, and the
finished-application suite covers one without.

Append to the root `CHANGELOG.md` and `shibuya-core/CHANGELOG.md` under an unreleased heading:
a bug-fix entry describing both corrected behaviors in user terms, and an other-changes entry
for the new process-isolated suite. `shibuya-metrics/CHANGELOG.md` gets its entry in Milestone 4.
Leave `docs/reviews/REV-16-childless-supervisor-gc-residual.md` as written; review records are
historical evidence. When the fix is committed, a new review record of the fixed commit is
welcome but is not required by this plan.

Acceptance is `nix fmt`, `nix flake check` and `cabal test shibuya-core` all passing, and no
present-tense document describing a linked supervisor.

### Milestone 4: Patch release

Follow `agents/skills/release/SKILL.md`. Before choosing a number, confirm the latest release
from Hackage and from the upstream tags; at the time of writing both show 0.9.0.2, so 0.9.0.3
is expected to be free. Bump `shibuya-core` and `shibuya-metrics` together, raise the metrics
package's `shibuya-core` bound to the new version, and move the changelog entries under the
versioned heading in all three changelogs. The release skill's benchmark step is skipped for a
patch. Run the full gates in Concrete Steps, build source distributions and documentation for
both packages, and show the owner the version, bounds and changelog. Do not commit the release,
tag, push or upload until the owner approves; then publish core before metrics.

Because plan 34 provisionally claimed 0.9.0.3, record the number this release consumed in the
Decision Log of
`docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md`
and update the provisional version statements in plan 34 and in
`docs/plans/35-align-adapter-effectful-bounds-and-releases-with-shibuya-core-0-9-0-3.md` to the
next patch. Do not rename plan files. Those plans are otherwise outside this one.

Acceptance is both packages served by Hackage at the approved version with documentation, a
pushed tag and a published GitHub release whose notes match what was built and tested.


## Concrete Steps

Run everything from the repository root inside the project's development shell.

After Milestone 1, expect failure:

```bash
cabal test shibuya-core:shibuya-core-gc-finished-test --test-show-details=direct
```

```text
FAIL [finite source, IgnoreFailures]: caller died after its application finished: ExceptionInLinkedThread (ThreadId 7) thread blocked indefinitely in an STM transaction
FAIL [finite source, StopAllOnFailure]: caller died after its application finished: ExceptionInLinkedThread (ThreadId 13) thread blocked indefinitely in an STM transaction
FAIL [failed source, IgnoreFailures]: caller died after its application finished: ExceptionInLinkedThread (ThreadId 20) thread blocked indefinitely in an STM transaction
```

Thread numbers vary. After Milestone 2, expect exit status zero and:

```text
PASS [finite source, IgnoreFailures]: caller survives major collections after its application finished
PASS [finite source, StopAllOnFailure]: caller survives major collections after its application finished
PASS [failed source, IgnoreFailures]: caller survives major collections after its application finished
```

The complete check after Milestone 2 and again after Milestone 3:

```bash
cabal build all
cabal test shibuya-core --test-show-details=failures
for i in 1 2 3; do cabal test shibuya-core:shibuya-core-gc-finished-test --test-show-details=direct; done
nix fmt
nix flake check
```

`cabal test shibuya-core` now reports three suites. New files must be added to git before
`nix flake check` can see them. The pre-commit hook runs the formatter and rejects an
unformatted commit after reformatting it; add the files again and commit again.

To prove after the fix that the tests would have caught the defect, use a worktree of the
Milestone 1 commit and give it the git dependency checkout, since an offline build cannot
clone it:

```bash
git worktree add --detach ../shibuya-ep46-red <milestone-1-commit>
mkdir -p ../shibuya-ep46-red/dist-newstyle
cp -R dist-newstyle/src ../shibuya-ep46-red/dist-newstyle/src
(cd ../shibuya-ep46-red && cabal test shibuya-core --offline --test-show-details=failures)
git worktree remove --force ../shibuya-ep46-red
```

The diagnostic probes can be rerun at any time. They print observations and always exit zero,
so they are not tests:

```bash
cabal build lib:shibuya-core --offline
mkdir -p .tmp/ep46
cabal exec --offline -- ghc -threaded -rtsopts -O1 -XGHC2024 -XOverloadedRecordDot \
  -XDuplicateRecordFields -XNoFieldSelectors -package-id shibuya-core-0.9.0.2-inplace \
  -outputdir .tmp/ep46 -o .tmp/ep46/childless scripts/audit/ChildlessSupervisorProbe.hs
.tmp/ep46/childless drop ignore +RTS -N2
```

Adjust the package identifier after a version bump. For the release, first check what is published:

```bash
git ls-remote --tags origin 'v0.9*'
curl -fsSL -H 'Accept: application/json' https://hackage.haskell.org/package/shibuya-core/preferred
curl -fsSL -H 'Accept: application/json' https://hackage.haskell.org/package/shibuya-metrics/preferred
```

Every commit carries these trailers:

```text
ExecPlan: docs/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md
Intention: intention_01m2ycc3fxedxtw5339e0efzy1
```


## Validation and Acceptance

The plan is accepted when all of the following can be observed. A program that runs an
application to completion, lets go of the handle and keeps running survives forced major
collections under both supervision strategies and after a source failure under
`IgnoreFailures`; `shibuya-core-gc-finished-test` demonstrates it and fails on the commit before
the fix. One processor failure under `StopAllOnFailure` reaches the caller as exactly one
`ExceptionInLinkedThread`; the new lifecycle case demonstrates it and reports two before the
fix. Sibling shutdown and failure propagation under `StopAllOnFailure`, isolation under
`IgnoreFailures`, deliberate halt, explicit shutdown and metrics behave as before, shown by the
unchanged existing suite passing. The idle-application regression from 0.9.0.2 still passes. No
public export or signature differs, which `shibuya-core/test/Shibuya/PublicApiSpec.hs` and a
review of the diff confirm. The released packages match what was tested.

Removing or weakening the per-processor links, swallowing exceptions in the caller, or
retaining the handle inside the library would each make a test pass without delivering the
behavior, and none is acceptable.


## Idempotence and Recovery

Both new tests are safe to run repeatedly: they use no external service and leave no state,
and the GC suite's process exit disposes of any remaining threads. The source change is a
few lines in one function and is reverted by reverting its commit. Building in a separate
worktree never touches the working tree; remove the worktree afterwards with the command
shown. If a future compiler makes the pre-fix tests pass, do not accept them as coverage;
re-establish a failing reproducer first, as the previous fix's plan also required.

A release cannot be undone once uploaded. Never overwrite a published version; if a gate fails
after the version bump, fix forward before anything is tagged or uploaded. Publication waits
for the owner's approval of the version and changelog.


## Interfaces and Dependencies

No dependency, bound or public interface changes. `nqe ^>=0.6` stays, and the change uses
three of its existing exports: the `Process` constructor and `newMailbox` from
`Control.Concurrent.NQE.Process`, and `supervisorProcess` from
`Control.Concurrent.NQE.Supervisor`. `async` comes from `UnliftIO`, already a dependency.

At the end of Milestone 2, `Shibuya.Internal.Runner.Master` still exports `Master (..)`,
`MasterState (..)`, `startMaster :: (IOE :> es) => Strategy -> Eff es Master`,
`stopMaster :: (IOE :> es) => Master -> Eff es ()`, and the metrics functions, all unchanged
in type. `MasterState.supervisor` is still an NQE `Supervisor`, so `addChild` in
`Shibuya.Internal.Runner.Supervised` works unchanged. The public `runApp`, `waitApp`,
`stopApp`, `stopAppGracefully`, `getAppMaster` and metrics readers in `Shibuya.App` are
unchanged. The package gains one test suite, `shibuya-core-gc-finished-test`.

The later core lifecycle plan in master plan 6 owns further changes to `Master.hs`, including
a retained lifecycle snapshot. It must keep both tests from this plan passing and must not
restore a link on the supervisor thread.
