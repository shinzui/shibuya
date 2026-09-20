---
type: Review
title: Master lifecycle review confirms an abandoned linked mailbox can crash healthy workers
description: Examination of the master module confirms the pre-fix GC crash, traces its introduction to 0.8, and identifies the limits of existing lifecycle coverage.
generated:
  by: process:codex-cli
  at: "2026-09-20T03:11:39Z"
reviewId: REV-1
subject: mori://shinzui/shibuya
subjectKind: component
component: Shibuya.Internal.Runner.Master
repository: mori://shinzui/shibuya/repos/shibuya
reviewedSha: 193a5c95525ec5eb19933e00f0014b8df0d3c03b
coverage: full
reviewedAt: "2026-09-20T03:11:39Z"
reviewerKind: model
reviewer: process:codex-cli
provider: openai
model: gpt-6-astra
effort: medium
outcome: changes-requested
dimensions:
  - correctness
  - design
  - test-coverage
  - operability
context: >-
  Captures the completed investigation of the entire master module at the pre-fix
  commit, with targeted inspection of App.waitApp, processor cleanup, tests, and
  Git history. Full coverage applies only to the named module, not the package
  or the broader concurrency audit. Historical test observations are from this
  session; a later fix is noted separately and is not an approval of that commit.
---

# Master lifecycle and garbage-collection regression

The review confirmed a severe availability defect: a healthy long-running application
could die while its caller was blocked in `waitApp`, solely because the unused master
mailbox became unreachable during garbage collection. The recommendation was to remove
the redundant linked actor and add a regression that does not retain the application
handle. The existing remediation owner is
[EP-33](../plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md).
That plan predates this review record, so it is not claimed as a newly produced artifact.

## Examination boundary

Read `shibuya-core/src/Shibuya/Internal/Runner/Master.hs` in full, including the
representation, creation, linking, message dispatch, cancellation, and direct metrics
operations. Supporting inspection covered `waitApp` in `shibuya-core/src/Shibuya/App.hs`,
registration and `finally` cleanup in `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`,
the lifecycle and runner tests, and the isolated probe in `shibuya-core/test-gc/Main.hs`.
Git history was used to locate the changed ownership relationship and its first release.

This is not a complete review of `App.hs`, `Supervised.hs`, Shibuya as a package, or its
adapters. Security, throughput, allocation performance, every shutdown interleaving, and
all supervision strategies were not exhaustively examined. A passing existing suite is
reported evidence, not a claim that those areas are proven correct. No consumer changes
or further examination of registration-service-v2 are part of this record.

## Confirmed finding: an obsolete actor remained linked to its caller

At the reviewed commit, `startMaster` creates an NQE supervisor plus a separate async
running `masterLoop`, and links that second thread to its caller. The loop blocks on
`receive inbox`. All internal metrics operations already access the metrics TVar directly;
no internal operation sends to this mailbox.

`waitApp` only needs the processor completion flags. When no other live code needs the
master mailbox, GHC can detect its thread as indefinitely blocked and raise
`BlockedIndefinitelyOnSTM`. The unconditional async link forwards that failure to the
application as `ExceptionInLinkedThread`. Queue processors can remain healthy throughout;
`IgnoreFailures` does not protect against this unconditional master link.

The triggering refactor is commit `f36418389cde6bb185c66a730819f4793acf2f86`, July 2,
2026: metrics reads, registration, and unregistration changed from mailbox queries to
direct STM operations to fix shutdown hangs. The mailbox actor was retained for
compatibility. Before the change, processor cleanup needed the mailbox; afterwards it
needed only the metrics state. The obsolete actor itself dates to the initial implementation.

That refactor first shipped in `v0.8.0.0`. The master source is unchanged between that
tag and `v0.9.0.1`. Therefore 0.9 inherited the defect. This version attribution rests on
source history; executable validation in this session used 0.9.0.1 rather than a runtime
bisect of every historical release.

## Confirmed coverage gap and the regression added

Commit `8ab1bcd`, released in 0.8.0.1, had already recorded the same linked-thread
exception as an intermittent test failure. It added `stopApp` after `waitApp` in finite
runner tests. That is valid cleanup, but the later use retains the handle and does not
exercise the lifetime of a worker whose sole remaining action is `waitApp`.

The original EP-33 test proposal used a weak pointer for cleanup. Once the handle has
been collected, that pointer can return `Nothing`, leaving threads alive in the test
process. The refresh replaced that design with a dedicated Cabal test executable. Its
observer receives only a startup signal, forces five major collections, and fails on
an exception, premature worker completion, or failure to complete the observation window.
Process exit handles test isolation without retaining the master to clean it up.

The test and refreshed plan were committed in the reviewed state, `193a5c9`.
`cabal test shibuya-core` and the release instructions select both core suites.

Observed at the pre-fix state under GHC 9.12.4 and normal `-O1` optimization:

```text
cabal test shibuya-core --offline --test-show-details=failures
Test suite shibuya-core-test: PASS
FAIL: bare waitApp died: ExceptionInLinkedThread (ThreadId 10) thread blocked indefinitely in an STM transaction
Test suite shibuya-core-gc-test: FAIL
```

A temporary copy of the GC probe that retained the master in an IORef survived the
same collections and printed `PASS: bare waitApp survives major collections`. This
control supports the reachability diagnosis; permanent retention is not the proposed fix.
`cabal check` reported no errors or warnings for the package. These observations were
made earlier in this session and are not new test runs during record creation.

## Remediation and subsequent state

EP-33 removes the unused mailbox, message protocol, async, and link while preserving
the actual NQE supervisor, direct metrics operations, and processor failure policy.
The GC test must pass after that removal, and existing lifecycle tests must continue
to cover normal completion, halt, failures, and shutdown. Merely removing exception
propagation or retaining the abandoned actor would not satisfy the recommendation.

When this record was captured, the checkout had advanced to
`c353a7dd79c58c20e289d3c5261c64745232b052` (`fix(core): remove idle linked master loop`).
Inspection confirms that commit's master module removes the redundant actor. EP-33
records the implementation and validation results. This later observation does not
change the pre-fix `reviewedSha` or its `changes-requested` outcome, and does not claim
an independent full review of the fix. A future review of that change should use a
separate record with its own examined commit and evidence.

## Recommended follow-up audit: not yet performed

The demonstrated gap warrants a focused lifecycle and concurrency audit of changes
introduced in 0.8 and inherited by 0.9, starting with EP-22's ownership and lifecycle
changes. The following are review questions, not additional confirmed defects:

- **Thread ownership:** For each spawned thread, identify its purpose, owner, live
  wait sources, exception links, and shutdown path. Look for obsolete actors left
  behind after direct-state refactors.
- **GC-sensitive lifetimes:** Exercise workers with no metrics server or retained
  application handle. A fixture's cleanup closure must not accidentally supply the
  very reference being tested.
- **Completion and cancellation:** Check normal completion, `AckHalt`, synchronous
  exceptions, and asynchronous cancellation. Each exit must resolve the relevant
  completion flags and release children so waiters do not hang.
- **Supervision policies:** Verify failure isolation for `IgnoreFailures` and sibling
  shutdown plus propagation for stop-all policies with runnable failure scenarios.
- **Adapter shutdown:** Examine polling, acknowledgement, lease management, and
  shutdown races for deadlocks and unintended stranded in-flight work. Each adapter
  requires its own scoped examination record if included in the later audit.

Use separate OKF review records for independently examined modules or components,
and route newly confirmed defects to their owning remediation artifacts. Do not mark
this broader audit complete based on the master-loop fix or the existing green tests.
