---
type: Review
title: "Master actor removal leaves a childless supervisor that can still kill its caller during garbage collection"
description: "Master actor removal leaves a childless supervisor that can still kill its caller during garbage collection; evidence, boundaries, and required follow-up are recorded."
generated:
  by: process:claude-code
  at: "2026-09-20T04:26:43Z"
reviewId: REV-16
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Internal.Runner.Master
reviewedSha: 7e70051d7acea949fd5b99c540c19ac1c36b1d88
coverage: full
reviewedAt: "2026-09-20T04:26:43Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5-1
effort: medium
outcome: changes-requested
dimensions:
  - correctness
  - test-coverage
  - operability
  - documentation
context: >-
  Independent second review of the EP-33 master-loop removal, requested by the
  project owner before the lifecycle remediation initiative begins. Full refers
  to source coverage of the Master module at this commit plus the NQE 0.6.6
  supervisor and process sources it delegates to; it is not an exhaustive
  concurrency proof. Both findings below are runtime reproductions, not
  source-only suspicions.
produced:
  - mori://shinzui/shibuya/plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc
---

# Master actor removal leaves a childless supervisor that can still kill its caller during garbage collection

Read the current `shibuya-core/src/Shibuya/Internal/Runner/Master.hs` in full, the
`waitApp`/`runApp`/`stopAppGracefully` paths in `shibuya-core/src/Shibuya/App.hs`, child
registration in `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`, the isolated
regression `shibuya-core/test-gc/Main.hs`, and the published NQE 0.6.6 sources
`Control.Concurrent.NQE.Supervisor` and `Control.Concurrent.NQE.Process`. The Master module
is unchanged since `c353a7d`; this record's `reviewedSha` is the examined checkout.

## What EP-33 fixed, confirmed

The redundant mailbox actor, its message protocol, its async and its unconditional link are
gone. `Master` is a newtype over `MasterState`; `stopMaster` cancels the real NQE supervisor.
The isolated GC regression covers an idle application with one live child and passes. This
review agrees with [REV-14](REV-14-master-fix-verification.md) on that scope: the removal
is correct, minimal, and does not alter public signatures or the failure policy.

## P2 — the supervisor is the same kind of thread, and is unreachable once it has no children

`startMaster` still calls `Supervisor.supervisor`, which is `process (supervisorProcess strat)`.
NQE's `process` creates a mailbox, runs the loop in an async, and **links that async to the
calling thread** — the thread that called `runApp`. The supervisor loop waits on:

```haskell
atomically $ Right <$> receiveSTM i <|> Left <$> waitForChild state

waitForChild state = do
  as <- readTVar state
  when (null as) retry
  waitAnyCatchSTM as
```

While at least one child is alive, the supervisor is reachable from that child's thread
through the child's async result variable, which is why the EP-33 regression passes. With
**zero children**, `waitForChild` retries and the only remaining wake source is the mailbox.
The mailbox is reachable only through the `Supervisor` value inside `Master`, that is, only
through the `AppHandle`. NQE removes a child from the list when it finishes under every
strategy, so every application whose processors have all completed, halted, or failed under
`IgnoreFailures` reaches this state.

If the caller then drops the handle without calling `stopApp` and keeps running, the next
major collection finds the supervisor blocked indefinitely, raises
`BlockedIndefinitelyOnSTM` in it, and the link forwards `ExceptionInLinkedThread` to the
thread that called `runApp`. This is the REV-1 failure class with a narrower trigger. It
also explains the historical symptom more completely: the four `RunnerSpec` cases that commit
`8ab1bcd` patched were finite-stream applications, which is exactly this state.

Runtime evidence, `scripts/audit/ChildlessSupervisorProbe.hs`, GHC 9.12.4, `-O1`, `-threaded`,
`+RTS -N2`, against the locally built 0.9.0.2 library at the reviewed commit. The probe runs a
finite (empty-source) application on the main thread, waits for `waitApp` to return, then
forces five major collections on that same thread. Three runs per cell, identical each time:

```text
RESULT drop/ignore: CALLER KILLED: ExceptionInLinkedThread (ThreadId 6) thread blocked indefinitely in an STM transaction
RESULT stop/ignore: caller survived
RESULT retain/ignore: caller survived
RESULT drop/stopall: CALLER KILLED: ExceptionInLinkedThread (ThreadId 6) thread blocked indefinitely in an STM transaction
RESULT stop/stopall: caller survived
RESULT retain/stopall: caller survived
```

`drop` discards the handle after `waitApp`; `stop` calls `stopApp` first; `retain` keeps the
handle alive past the collections. `ignore` and `stopall` are `IgnoreFailures` and
`StopAllOnFailure`. Both controls survive, which isolates reachability of the childless
supervisor as the cause.

Reachable production shapes include a long-lived process that runs a finite or haltable
application and then continues on the same thread, a service whose processors have all
halted through `AckHalt` or all failed under `IgnoreFailures` while the `runApp` thread
serves something else, and any test suite that does not call `stopApp`. A process that exits
right after `waitApp` returns is unaffected. Retaining the master for a metrics server also
masks it. The documented contract does say the caller is responsible for stopping the master;
the defect is that the penalty for omitting it is an asynchronous exception delivered to an
unrelated point of the caller at a time chosen by the garbage collector.

## P2 — the same link delivers one processor failure twice

`Supervised` links every processor to the caller when the strategy propagates failures. Under
that strategy NQE's supervisor also stops the siblings and rethrows the child's exception, so
the supervisor's own link fires for the same failure. `scripts/audit/LinkedFailureDeliveryProbe.hs`
starts one processor whose source throws under `StopAllOnFailure`, retains the handle so that
garbage collection plays no part, and counts what the calling thread receives. Three runs:

```text
probe-dd: Uncaught exception ghc-internal:GHC.Internal.IO.Exception.SomeAsyncException:

ExceptionInLinkedThread (ThreadId 8) user error (boom)
probe-dd: Uncaught exception ghc-internal:GHC.Internal.IO.Exception.SomeAsyncException:

ExceptionInLinkedThread (ThreadId 6) user error (boom)
RESULT deliveries=2
  ExceptionInLinkedThread (ThreadId 8) user error (boom)
  ExceptionInLinkedThread (ThreadId 6) user error (boom)
```

Thread 8 is the processor and thread 6 the supervisor. In two of three runs the second
exception landed between the probe's handlers and terminated the process. An application that
catches the first failure and begins an orderly shutdown is exposed to the same thing. The
existing propagation test observes only that a failure arrives, not how many times.

## Required correction and regression

Do not reintroduce a retained root or an idle actor. Give the supervisor thread an ownership
model in which an unreachable, childless supervisor is simply collected rather than
reported as a failure of the caller. `Supervised` already links each child individually when
the strategy propagates failures, so the unconditional supervisor link is not what delivers
processor failures; verify that before removing or filtering it, and keep
`StopAllOnFailure` propagation and sibling shutdown covered by the existing lifecycle tests.

Regression acceptance: extend the process-isolated GC suite with a finite application whose
handle is dropped after `waitApp` returns while the calling thread continues through forced
major collections. It must fail on the reviewed commit with the exception above and pass
after the fix, for both supervision strategies, without retaining the handle for cleanup. Add
a lifecycle test asserting that one processor failure under `StopAllOnFailure` reaches the
caller exactly once.

A prototype that assembles the `Process` from `newMailbox` and an unlinked async, leaving
everything else alone, was built in an isolated worktree during this review: the first probe
then reports `caller survived` in all 18 runs, and both existing core suites pass with 212
examples and zero failures. That is feasibility evidence, not a review of a committed fix.

## Boundaries

This is not a claim that EP-33 was wrong or that 0.9.0.2 regressed anything: the state
predates the actor removal and was present in every release that used an NQE supervisor.
No production code was changed by this review. At the project owner's direction the
remediation is a standalone, urgent plan,
[EP-46](../plans/46-unlink-the-nqe-supervisor-so-a-finished-app-cannot-kill-its-caller-during-gc.md),
independent of the lifecycle remediation master plan.

See [audit summary and reproduction commands](../lifecycle-audit-progress.md); compile this
first probe with the same `cabal exec … ghc` invocation used there for `LifecycleProbe.hs`, adding
`-rtsopts`, and run it as `probe <drop|stop|retain> <ignore|stopall> +RTS -N2`. The delivery
probe compiles the same way and takes no arguments.
