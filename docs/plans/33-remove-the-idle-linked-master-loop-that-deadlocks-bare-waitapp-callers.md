---
id: 33
slug: remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers
title: "Remove the idle linked master loop that deadlocks bare waitApp callers"
kind: exec-plan
created_at: 2026-09-16T22:33:21Z
intention: intention_01m2ycc3fxedxtw5339e0efzy1
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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-20T03:01:02Z
      mode: "update"
      note: "Refresh history, process-isolated regression and release coordination; implement the failing test and exclude RS2 per user clarification."
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T03:05:33Z
      mode: "implement"
      note: "Implement remaining milestones and link the new intention"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-20T02:54:27Z
      verdict: "changes-requested"
      note: "Core fix is sound; replace weak-pointer cleanup, correct NQE liveness and regression history, add RS2 acceptance, and reconcile release coordination."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-09-20T03:02:02Z
      verdict: "approved"
      note: "Refreshed plan resolves review findings; isolated regression reproduces the crash, retention control and existing suite pass, release gate includes both suites, and RS2 remains out of scope. Library fix pending."
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-09-20T04:45:51Z
      verdict: "comments"
      note: "Fix is correct and minimal for an idle app with a live child; REV-16 reproduces that the remaining NQE supervisor link still kills callers of finished apps during GC and double-delivers failures; remediation is standalone plan 46."
---

# Remove the idle linked master loop that deadlocks bare waitApp callers

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current. All milestones are complete: the failing regression,
library fix, documentation, 0.9.0.2 release, and MLS consumer follow-up are implemented and
verified.


## Purpose / Big Picture

An application that calls `runApp` and then only `waitApp` can die during a major garbage
collection even while its queue processors are healthy:

```text
ExceptionInLinkedThread (ThreadId ...) thread blocked indefinitely in an STM transaction
```

Remove the unused linked master mailbox thread. The public application API, real NQE
supervisor, metrics registry, and processor failure policy remain unchanged. After the fix,
a caller need not retain the master merely to keep an idle application alive.

The dedicated regression executable already exists in
`shibuya-core/test-gc/Main.hs`, registered as `shibuya-core-gc-test`. It exercises the public
API without PostgreSQL, a metrics server, a retained handle, or a cleanup closure capturing
the application. It must fail before the fix and pass afterwards:

```bash
cabal test shibuya-core-gc-test --test-show-details=direct
```

Scope is the core fix, its tests and documentation, coordinated release preparation, and the
existing follow-up in `mori://tan/mls-service-v2`. Per the user's clarification,
`mori://tan/registration-service-v2` is outside the implementation and follow-up scope.


## Progress

- [x] (2026-09-20 UTC) Review the original plan against current source, history, package registry, and upstream release tags.
- [x] (2026-09-20 UTC) Milestone 1: Add the dedicated GC regression executable and confirm failure with the reported linked-thread exception on 0.9.0.1.
- [x] (2026-09-20 UTC) Milestone 2: Remove the master loop, mailbox, and message protocol; make the regression and existing lifecycle tests pass.
- [x] (2026-09-20 UTC) Milestone 3: Update current architecture descriptions and retain accurate historical explanations.
- [x] (2026-09-20 UTC) Milestone 4: Prepare and validate the coordinated release; publish through the release workflow.
- [x] (2026-09-20 UTC) Milestone 5: Update the MLS consumer's pins and verify its isolated worker survives.


## Surprises & Discoveries

**The runtime regression predates 0.9.** Commit `f36418389cde6bb185c66a730819f4793acf2f86`
(July 2, 2026, "fix(runner): repair ingester and metrics shutdown paths") replaced mailbox
queries in all metrics reads, registration, and unregistration with direct STM operations.
It first shipped in `v0.8.0.0`. Previously, a running processor's eventual
`unregisterProcessor` needed the master's mailbox; afterwards it needed only the metrics
state. The linked actor itself dates to the initial implementation. The combination left a
thread waiting on a mailbox with no internal senders. The current master source is identical
between `v0.8.0.0` and `v0.9.0.1`; this is history-based attribution, not a runtime bisect
of every old release. EP-26 later removed obsolete metrics query constructors but was not the
originating change.

**A previous test fix saw the same symptom.** Commit `8ab1bcd`, first released in 0.8.0.1,
added `stopApp` after `waitApp` in four `RunnerSpec` cases. This was valid cleanup for
finite streams but retained the application for that later call. It did not cover an infinite
worker whose only remaining use of the handle is `waitApp`.

**Weak pointers cannot guarantee teardown.** The original plan's `mkWeakPtr app` cleanup
could return `Nothing` precisely when the test succeeded in allowing collection. An idle
adapter could therefore survive into later tests. The replacement is a dedicated Cabal test
process: its exit terminates all remaining threads without retaining the master during the
observation window. This is a test isolation technique, not a production shutdown policy.

**The real supervisor has a live wait source.** Mori has no registered NQE corpus. The
published [NQE 0.6.6 supervisor source](https://hackage.haskell.org/package/nqe-0.6.6/src/src/Control/Concurrent/NQE/Supervisor.hs)
shows `receiveSTM i <|> waitForChild state`; `waitForChild` uses `waitAnyCatchSTM` on
the active children. The [process source](https://hackage.haskell.org/package/nqe-0.6.6/src/src/Control/Concurrent/NQE/Process.hs)
shows `process` creates an async and links it. The supervisor can therefore be woken by a
child's completion independently of its mailbox. Do not justify its liveness by assuming that
an optimized child closure retains the whole `Master`. Preserve the supervisor and verify
the complete app under GC after removing only the redundant master actor.

**Release baseline checked during this refresh.** The Hackage version endpoints for
[core](https://hackage.haskell.org/package/shibuya-core.json) and
[metrics](https://hackage.haskell.org/package/shibuya-metrics.json), plus
`git ls-remote --tags origin 'v0.*'`, all list 0.9.0.1 as the latest release.
The 2026-09-20 release recheck returned the same result, leaving 0.9.0.2 free.

The new test compiled under GHC 9.12.4 with Cabal's normal `-O1` library/test profile and
failed as required:

```text
FAIL: bare waitApp died: ExceptionInLinkedThread (ThreadId 10) thread blocked indefinitely in an STM transaction
0 of 1 test suites (0 of 1 test cases) passed.
```

A separate diagnostic in this session also reproduced the failure and survived when the master
was retained in an IORef. A temporary copy of the new test, with that same retention added,
likewise printed `PASS: bare waitApp survives major collections` under `-O1` and two runtime
capabilities. That control supports the reachability diagnosis; retaining the master is not
the planned library fix and is absent from the committed-test candidate.

**Removing only the obsolete actor fixes the failure.** With `Master` reduced to its state,
the dedicated GC executable passed three consecutive runs under GHC 9.12.4 and `-O1`, and
the complete core suite passed all 212 Hspec examples plus the dedicated executable. A
detached worktree at pre-fix commit `9e2a038` reproduced the original failure with the same
test:

```text
FAIL: bare waitApp died: ExceptionInLinkedThread (ThreadId 10) thread blocked indefinitely in an STM transaction
0 of 1 test suites (0 of 1 test cases) passed.
```

**The current concurrency and message-flow references were already actor-free.** Inspection
of `docs/architecture/CONCURRENCY.md` and `docs/architecture/MESSAGE_FLOW.md` found that both
already describe `Master` as the owner of the supervisor and metrics map. The stale actor
descriptions were confined to the explicitly historical design/incident documents and the
processor-pause proposal; those now label their actor snippets as historical.

**The 0.9.0.2 candidate passes every pre-publication gate.** `cabal build all`, both suites
selected by `cabal test shibuya-core`, `nix fmt`, `nix flake check`, and `cabal check` for both
packages passed after the version and changelog edits. Cabal also produced source and Hackage
documentation tarballs for core and metrics at 0.9.0.2. Haddock emitted only the repository's
existing missing-link and coverage warnings; generation succeeded for both packages.

**Release 0.9.0.2 is public.** Commit `d27448e` is tagged `v0.9.0.2` and pushed. Hackage
serves both `shibuya-core-0.9.0.2` and `shibuya-metrics-0.9.0.2`, including their Haddocks,
and the GitHub release is published at
<https://github.com/shinzui/shibuya/releases/tag/v0.9.0.2>. Post-publication requests for
both Hackage package pages returned HTTP 200 and `gh release view` reported a non-draft,
non-prerelease release for the tag.

**The MLS consumer accepts the fixed release without an unrelated dependency refresh.** In
`mori://tan/mls-service-v2`, commit `536b107` advances the Hackage snapshot to
`2026-09-20T04:00:02Z`, pins core and metrics to 0.9.0.2, and constrains every package that
the later snapshot initially tried to move back to its prior frozen version. The resulting
freeze and generated Nix overlay change only core and metrics. `just update-cabal-freeze`
passed the complete 282-test suite, `cabal build exe:mls-service-v2` was up to date, and
`nix flake check` passed the package, test, generated-overlay, pre-commit, and formatting gates.

**The isolated MLS worker survives the former crash window.** The repository-local PostgreSQL
17.10 database had an empty `location_service_area_details_cache` queue. The resolved,
pre-built binary ran `queue-worker run-area-details-cache` under a 40-second GNU timeout and
returned status 124. PostgreSQL recorded successful queue polls every five seconds throughout
the bounded run, and neither the process output nor database log contained the linked-thread
exception. The current development shell supplies PostgreSQL 18.6 and could not start over the
existing version-17 data directory; this setup mismatch was kept separate from the worker
proof, which used the already-running, repository-local version-17 server verified by `psql`.


## Decision Log

- Decision (2026-09-16, retained): Remove the unused actor rather than add a permanent root or
  another accidental reference. Its operations already access STM state directly.
- Decision (2026-09-16, retained): Keep the opaque public `Master` and all public accessors.
  Only the expressly unstable `Shibuya.Internal.Runner.Master` representation changes.
- Decision (2026-09-16, retained): Keep `RunnerSpec` shutdown calls; correct their comments
  once the actor is removed.
- Decision (2026-09-20 UTC, supersedes the weak-pointer test): Use a separate, failing-first
  Cabal test executable with startup synchronization, bounded observation, and forced GC.
  Ordinary core validation and release gates must run both core test suites.
- Decision (2026-09-20 UTC): Preserve the parent's provisional 0.9.1.0 coordination target,
  but do not assert that this diff inherently requires a minor bump. The release skill
  classifies internal-only fixes as patch changes; inspect the complete release diff and
  unstable-module policy before choosing the actual version. Reconcile the parent and
  dependent plans if the final choice differs.
- Decision (2026-09-20 UTC, supersedes the provisional 0.9.1.0 target): Release this
  internal-only fix as PVP patch 0.9.0.2 without plan 34's unstarted dependency work.
  Rationale: The public `Master` remains opaque and every public signature is unchanged;
  although its expressly unstable internal module is exposed, its no-PVP-guarantee contract
  permits representation changes in a patch. Holding the runtime fix for independent bound
  hardening would delay the most serious defect in the initiative. Plan 34 owns the following
  patch release, provisionally 0.9.0.3.
- Decision (2026-09-20 UTC): The user's clarification excludes
  `mori://tan/registration-service-v2` from follow-up. The initial review provenance's
  suggestion to add that consumer is superseded by this explicit scope decision.
- Decision (2026-09-20 UTC): Keep the NQE supervisor cancellation as the complete
  `stopMaster` implementation after removing the mailbox actor. This preserves child teardown
  and failure propagation while eliminating the only unreachable STM wait.


## Outcomes & Retrospective

The review found the removal design sound and the implementation removes the obsolete
mailbox actor without changing public APIs, metrics access, supervisor behavior, or failure
propagation. The dedicated process-isolated regression passes repeatedly, the old actor fails
the same test in a detached worktree, and all existing core tests pass. Release 0.9.0.2 is
published for both core and metrics with matching Haddocks, tag, and GitHub release. The MLS
consumer pins both packages, preserves every unrelated frozen version, passes its complete
build/test/flake gates, and its isolated worker remains alive until the bounded timeout while
polling the local queue. All milestones are complete.

Refresh validation: `cabal test shibuya-core --offline --test-show-details=failures`
selected both suites: the existing Hspec suite passed and the GC suite failed with the
expected linked STM exception. `cabal check` reported no warnings or errors. `nix fmt`
and explicit Fourmolu formatting of the new file completed, and `git diff --check` passed.
Current-tree validation after the documentation update passed `cabal build all`, both suites
selected by `cabal test shibuya-core --test-show-details=failures`, `nix fmt`, and
`nix flake check`. The prepared 0.9.0.2 candidate repeated those gates, passed `cabal check`
for both packages, and produced both source distributions and Hackage documentation tarballs.
The exact artifacts were published after user approval. Downstream verification selected the
published versions and reproduced the expected long-running worker behavior.


## Context and Orientation

`shibuya-core/src/Shibuya/Internal/Runner/Master.hs` now defines `Master` as a newtype around
`MasterState`. `startMaster` creates only the NQE supervisor and metrics registry, and
`stopMaster` cancels the supervisor. The removed representation also had an `Async` handle,
an inbox, and a linked `masterLoop` whose mailbox had no senders. Metrics operations continue
to use the registry directly.

`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` registers processors, adds children
to `master.state.supervisor`, and unregisters metrics in `finally`. The
`propagateFailures` field controls child links. It does not use the master inbox or handle.
Keep this policy and the completion-flag `finally` intact.

`shibuya-core/src/Shibuya/App.hs` creates the master and processors, exports the opaque
master and metrics readers, and implements graceful shutdown. Its `waitApp` reads only
processor completion TVars. An STM transaction is an atomic operation on shared transactional
variables; when it cannot proceed it waits for one of those variables to change.
`BlockedIndefinitelyOnSTM` is the runtime's diagnosis that the wait cannot be woken through
reachable state, not a queue-idle timeout. A linked async forwards failure to its creator.

The timer-backed adapter in `shibuya-core/test-gc/Main.hs` models an idle polling source.
Its worker signals startup with an empty MVar filled with `()` (a synchronization cell),
then calls bare `waitApp`. The observer waits for that signal, forces five major collections
with scheduling gaps, and checks that the worker remains blocked rather than failing or
returning. The five-second outer deadline fails if the observation cannot finish. Neither
the observer nor the signal retains the application. Do not substitute an unreachable
`atomically retry` adapter; that would introduce another deadlock.

`shibuya-core/test/Shibuya/App/LifecycleSpec.hs` covers finite completion, halt, failures,
shutdown and metrics. `shibuya-core/test/Shibuya/RunnerSpec.hs` has four explicit cleanup
calls so supervisors and children do not outlive their tests. `shibuya-core/shibuya-core.cabal`
declares both test suites.
`CLAUDE.md` and `.agents/skills/release/SKILL.md` must direct normal checks to
`cabal test shibuya-core`, which selects both.

This plan created `docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md`.
Relevant earlier design context is in
`docs/plans/22-fix-processor-lifecycle-and-supervision-semantics.md` (direct STM metrics
and conditional failure propagation) and `docs/plans/25-pre-1-0-public-api-cleanup.md`
(unstable internals). ADR 0001 distills the completed lesson about obsolete linked actors,
supervisor ownership, and process-isolated GC-liveness tests without inventing an OKF identity
for a repository that has no ADR bundle.

The existing consumer diagnosis is
`mori://tan/mls-service-v2/plans/101-find-and-fix-the-queue-worker-s-per-message-memory-retention`.
Mori currently cannot resolve that artifact, but the plan exists in the registered checkout.
Keep the canonical URI. The consumer paths below are relative to `mori://tan/mls-service-v2`;
artifact-level URIs for these individual source/configuration files are pending.


## Plan of Work

### Milestone 1: A permanent regression, failing before the fix

This milestone now has source and failure evidence. Keep
`shibuya-core/test-gc/Main.hs` and its Cabal stanza. Confirm the failure is the linked STM
exception rather than a compile error, startup error, outer deadline, or early return.
Do not weaken the assertion to accept the exception, mark it pending, or retain the master
to make it pass. An intentional failing test remains visible until Milestone 2.

The separate process is necessary to isolate teardown. Existing lifecycle tests remain
responsible for verifying explicit shutdown. The new executable proves the missing case:
a running app whose caller only waits. Its success message is emitted only after the
post-startup GC window finishes and the worker has not completed.

### Milestone 2: Remove only the obsolete actor

Delete `MasterMessage`, `masterLoop`, `handleMessage`, and the master's `handle` and
`inbox` fields. Make `Master` a newtype around `MasterState`. Remove the redundant
async/link creation and its cancellation, keeping the real NQE supervisor lifecycle.
Keep the metrics operations and `propagateFailures` mapping unchanged.

Retain `Process (..)` from `Control.Concurrent.NQE.Process`: `getProcessAsync` still
comes from it. Remove only `Inbox`, `Listen`, `newInbox`, and `receive`, plus the
unused `forever`, `async`, `link`, and `Async` imports. Update module Haddock to
describe an owner of supervisor state and metrics rather than a mailbox actor.

Acceptance is a passing GC regression under normal optimization, plus the existing lifecycle,
failure-isolation, halt, metrics, and shutdown suites. Do not remove real supervisor/child
links to suppress the exception. Confirm that the existing strategy tests still exercise
propagation and isolation.

### Milestone 3: Documentation and checks

Correct current actor descriptions in `CLAUDE.md`, `docs/MULTI_QUEUE_DESIGN.md`,
`docs/HIGH_LEVEL_ARCHITECTURE.md`, and `docs/architecture/RUNNER_BUG_FIXES.md`.
Also inspect `docs/architecture/CONCURRENCY.md` and `docs/architecture/MESSAGE_FLOW.md`
for stale snippets. Label historical code as historical. Annotate
`docs/plans/PROCESSOR_PAUSE_DESIGN.md` so its proposed message protocol is not mistaken
for an existing interface. Replace all four obsolete explanations in `RunnerSpec` with
the valid reason to stop apps: supervisors and children must not outlive their tests.

Acceptance is accurate present-tense documentation, both core suites in normal/release
commands, formatting, and the existing flake checks. Do not rewrite unrelated archived plans.

### Milestone 4: Core and metrics patch release

This plan is EP-1 in master plan 5. Plan 34 remains unstarted, so this release follows the
parent's independent-release path and includes only the crash fix, regression, and related
documentation. Plan 34 owns the following dependency-bound patch.

Use `.agents/skills/release/SKILL.md`, which resolves through the installed skill symlink
to the tracked `agents/skills/release/SKILL.md`; both paths are valid in this checkout.
Its version and changelog review precedes release commits, tags, and publication; prepare
the concrete diff first. Live Hackage metadata and upstream tags both stop at 0.9.0.1, so the
reviewed patch target is 0.9.0.2. The internal module explicitly disclaims PVP stability but
is still listed in Cabal's exposed modules; the Decision Log records why a patch is appropriate.
Master plan 5 and plans 34–36 are synchronized before release.

Update both package cabal versions, the metrics dependency bounds, the root changelog, and
both package changelogs. Recheck Hackage and upstream tags before choosing a free version.
Publish core before metrics. Apply the installed release skill's checks, including the new GC
suite; if EP-34 has changed the benchmark policy, use that updated policy too.

### Milestone 5: Existing MLS consumer follow-up

Use Mori to locate `mori://tan/mls-service-v2`. As inspected, its
`cabal.project.freeze` and `nix/haskell-overlay.nix` pin core and metrics to 0.9.0.0.
Its `Justfile` recipe `update-cabal-freeze` removes the freeze, builds/tests, freezes,
and regenerates the overlay; it does not by itself promise the intended version. Constrain
or select the actual fixed version using that repository's dependency workflow, regenerate,
then inspect both files and the solver output. Avoid accepting unrelated dependency upgrades.

Verify `queue-worker run-area-details-cache` against an isolated development database and
test service endpoints, after reading that repository's instructions. This command consumes
real queue work: do not point it at a production queue for a liveness check. A startup/config
failure is not evidence about this fix. Record successful startup, the bounded observation,
selected package versions, and absence of the linked-thread exception.

The parent retains this consumer follow-up; no additional consumer repository is in scope.


## Concrete Steps

Run core commands from this repository root in its existing development environment.

### Verify the regression

```bash
cabal test shibuya-core-gc-test --test-show-details=direct
```

Before the library fix, expect nonzero exit and the linked STM exception quoted above.
After the fix, expect exit zero and:

```text
PASS: bare waitApp survives major collections
```

Do not change the test's normal optimization settings to obtain a misleading green result.
If future compiler changes make the pre-fix test pass, establish an effective reproducer
before accepting it as regression coverage.

### Change Master.hs

The resulting representation and lifecycle are:

```haskell
newtype Master = Master {state :: MasterState}
  deriving (Generic)

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

stopMaster :: (IOE :> es) => Master -> Eff es ()
stopMaster master = liftIO $ cancel (getProcessAsync master.state.supervisor)
```

`MasterState` and direct metrics functions remain unchanged. Search for removed fields and
constructors across source, tests, and benchmarks before building; no external reference
was found during this review.

```bash
rg -n 'MasterMessage|masterLoop|master\.inbox|master\.handle' shibuya-core shibuya-metrics shibuya-core-bench
cabal build all
cabal test shibuya-core --test-show-details=direct
nix fmt
nix flake check
```

A zero-match `rg` exits 1; that is expected after removal and is not a build failure.
The package-level test target runs both the existing Hspec suite and the GC executable.
Repeat the short GC executable three times after the fix, recording results; do not substitute
repeated full-suite runs for the targeted GC proof. During implementation, also demonstrate
that restoring the obsolete actor in an isolated checkout makes the same test fail.

### Prepare release evidence

```bash
git ls-remote --tags origin 'v0.*'
curl -fsSL https://hackage.haskell.org/package/shibuya-core.json
curl -fsSL https://hackage.haskell.org/package/shibuya-metrics.json
git diff --check
```

Follow the release skill for the actual bump, changelogs, bounds, benchmarks when required,
source distributions, Haddocks, tags, and uploads. This refresh authorizes none of those
publication actions.

### Validate the MLS consumer

First resolve the checkout:

```bash
mori registry show tan/mls-service-v2 --full
```

In that checkout, after selecting the fixed version and configuring isolated development
resources:

```bash
just update-cabal-freeze
rg -n 'shibuya-(core|metrics)' cabal.project.freeze nix/haskell-overlay.nix
cabal build exe:mls-service-v2
```

Build before the timed run, so compilation cannot consume the liveness window. Resolve the
binary with `cabal list-bin exe:mls-service-v2`, then run that binary under a 40-second
timeout with `queue-worker run-area-details-cache`. On systems with GNU `timeout`,
use `timeout 40 <resolved-binary> queue-worker run-area-details-cache`; on macOS use
`gtimeout` if installed. Record the real exit status immediately. Status 124 means the
timeout ended the process; require the startup evidence as well. If neither timeout command
exists, supply an equivalent bounded process runner rather than treating that missing tool
as a Shibuya failure. Commit the consumer's freeze and overlay together when implementing
that milestone, following its own repository rules.


## Validation and Acceptance

Milestone 1 is complete only with a compiled, non-pending test that fails with the reported
exception against the unchanged library. That evidence is recorded above.

Milestone 2 requires the same test to pass, all existing core tests to pass, and unchanged
public exports and signatures. The production source must contain no idle master mailbox
actor; removing its link alone is not acceptance.

Milestone 3 requires accurate current descriptions, passing formatting/flake checks, and a
standard core/release test command that includes the dedicated GC suite.

Milestone 4 requires both packages published at the reviewed version and the tag and
changelogs matching what was built and tested. Build/publish preparation is not publication.

Milestone 5 requires verified fixed dependency pins and an isolated MLS worker that starts
successfully and remains alive for the entire observation. Explicit shutdown and processor
failure behavior must still be covered by the core lifecycle suite.


## Idempotence and Recovery

Re-run the dedicated test freely: it has no external service or data dependency, and each
process terminates its own threads. Its observer signals success only after forced GC;
an outer timeout is failure. This avoids both accidental handle retention and weak-pointer
cleanup leaks. The regular suite continues to test production shutdown.

Keep the regression green through the release gates; do not publish a release with a failing
suite. Source changes are reversible with scoped patches or commits. Preserve unrelated work.
Consumer pin updates remain in their own repository. Release retries follow the release skill;
never overwrite an existing version.

The old release/consumer commands were instructions for later milestones, not evidence that
those actions had already happened.


## Interfaces and Dependencies

No runtime dependency or public API change is needed. `nqe ^>=0.6` remains. The new test
uses already-selected `base`, `effectful`, `shibuya-core`, `streamly-core`, and
`unliftio`; it adds no external service requirement.

The resulting internal representation is `newtype Master = Master {state :: MasterState}`.
`MasterState` still contains the metrics registry, NQE supervisor and failure-propagation
flag. `MasterMessage`, `Master.handle`, and `Master.inbox` disappear from the unstable
internal module. Public `runApp`, `waitApp`, `stopApp`, `stopAppGracefully`,
`getAppMaster`, and all metrics-reader signatures stay unchanged.

Release coordination is soft, not a compiler dependency: this plan owns patch 0.9.0.2 with
the crash fix, plan 34 owns dependency-bound and benchmark-policy hardening plus the following
patch, plan 35 consumes that later bound release, and plan 36 can consume 0.9.0.2 directly.


## Revision Notes

2026-09-20 UTC: Reviewed the original plan, verified the 0.8 regression history and current
0.9.0.1 release baseline, corrected NQE liveness and weak-pointer teardown assumptions,
implemented and reproduced the dedicated GC regression, and refreshed test/release gates,
documentation scope, and MLS follow-up. The user's clarification explicitly excludes
registration-service-v2. Production implementation and publication remain pending.

2026-09-20 UTC: Linked intention `intention_01m2ycc3fxedxtw5339e0efzy1`, removed the idle
master mailbox actor, and verified the fix with three optimized GC runs, the full core suite,
and a detached pre-fix reproduction. Updated the living sections to record Milestone 2;
documentation, release, and MLS consumer follow-up remain.

2026-09-20 UTC: Updated current architecture descriptions, marked historical master-actor
snippets and the pause protocol proposal explicitly, corrected lifecycle-test cleanup comments,
and passed the full build, both core suites, formatting, and flake checks. Milestone 3 is
complete; release and MLS consumer follow-up remain.

2026-09-20 UTC: Selected PVP patch 0.9.0.2 after live Hackage/tag verification, prepared both
package versions, bounds, and changelogs, and synchronized master plan 5 plus plans 34–36.
Plan 34 remains separate and provisionally owns 0.9.0.3. Release approval, publication, and
MLS verification remain.

2026-09-20 UTC: Validated the concrete 0.9.0.2 candidate with the full build, both core suites,
formatting and flake checks, per-package `cabal check`, source distributions, and Hackage
documentation tarballs. The release commit, tag, push, and uploads await the release skill's
required version/changelog confirmation.

2026-09-20 UTC: Published shibuya-core and shibuya-metrics 0.9.0.2 to Hackage with Haddocks,
pushed annotated tag `v0.9.0.2`, and published the matching GitHub release. Milestone 4 is
complete; only the MLS consumer pin and isolated worker observation remain.

2026-09-20 UTC: Updated `mori://tan/mls-service-v2` to exact core/metrics 0.9.0.2 pins without
moving any unrelated frozen dependency, regenerated its Nix overlay, passed all 282 tests and
flake checks, and observed its repository-local area-details worker polling until a 40-second
timeout returned 124. Added ADR 0001 for obsolete linked actors and GC-sensitive liveness.
Milestone 5 and this ExecPlan are complete.
