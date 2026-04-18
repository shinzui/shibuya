# Provide NFData instances for core message types

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

People who benchmark code that uses the Shibuya framework need `NFData` instances on
Shibuya's public message types so that benchmark harnesses can fully evaluate (`deepseq`,
`nfIO`, `nf`) the values those harnesses produce and consume. Today Shibuya does not
provide those instances, so every benchmark author has to write the same three orphan
instances at the top of their benchmark module:

    deriving anyclass instance NFData MessageId
    deriving anyclass instance NFData Cursor
    deriving anyclass instance (NFData a) => NFData (Envelope a)

Those instances are orphans because the types are defined in `shibuya-core` but the
instances live in another package. Orphans produce GHC warnings, leak into downstream
packages, and collide with each other if two independent benchmarks (or a library and a
benchmark) both declare them. The fix is to provide the instances once, in the package
that owns the types.

After this change a benchmark author can import `Shibuya.Core.Types` (directly or via
`Shibuya.Core`) and immediately use `nfIO`, `nf`, or `deepseq` on values of type
`MessageId`, `Cursor`, or `Envelope a` (whenever `a` itself has an `NFData` instance)
without declaring any orphan. They can see it working by deleting the three orphan
instances from their benchmark module, rebuilding, and observing that the benchmark
still compiles and runs — and that the `-Worphans` GHC warning (or equivalent) is gone.

The NFData type class comes from the `deepseq` package, which ships with GHC. An
`NFData` instance provides `rnf`, a function that forces a value to normal form (every
constructor and every field fully evaluated). Benchmark libraries such as `tasty-bench`
and `criterion` use `rnf` under the hood to ensure that timing measurements capture the
full work of producing a value rather than just constructing a thunk.


## Progress

- [x] Milestone 1 — Add `NFData` instances for `MessageId`, `Cursor`, and `Envelope` in
      `shibuya-core/src/Shibuya/Core/Types.hs` and add `deepseq` to the
      `shibuya-core.cabal` library build-depends. (2026-04-18 — library builds clean,
      all 91 core tests pass.)
- [x] Milestone 2 — Demonstrate the instances work by removing any redundant orphan or
      local derivation inside `shibuya-core-bench/` that is now satisfied by the library
      instances, rebuilding, and running the benchmark suite in smoke-test mode.
      (2026-04-18 — replaced `length msgs \`deepseq\`` with `map (.envelope) msgs
      \`deepseq\``; forces `NFData (Envelope BenchMessage)` on every run. Confirmed via
      `cabal bench shibuya-core-bench --benchmark-options='-p mock-adapter-100'`.)
- [x] Milestone 3 — Record the addition in `CHANGELOG.md` under a new `Unreleased`
      section so downstream users know the instances are now available. (2026-04-18)


## Surprises & Discoveries

- 2026-04-18 — The Milestone 2 plan originally said to force the whole `[Ingested es
  BenchMessage]` list via ``msgs `deepseq` ...``. That does not typecheck: `Ingested`
  contains an `AckHandle es`, which is a `newtype` around a function
  `AckDecision -> Eff es ()`. Functions do not have a useful `NFData` instance, and
  deriving `NFData` for `AckHandle` via Generic fails for the same reason. The fix is
  to force only the envelope component — ``map (.envelope) msgs `deepseq` ...`` — which
  still exercises every new library-provided instance (`Envelope`, `MessageId`, and
  transitively `Maybe Cursor`) and was the actual intent of the milestone. No library
  change is needed; only the bench edit had to shift.

- 2026-04-18 — `cabal run shibuya-core-bench` is ambiguous: the `shibuya-core-bench`
  package ships both a `benchmark` component and an `executable standalone-test`, and
  `cabal run` picks the executable. Use `cabal bench shibuya-core-bench
  --benchmark-options='...'` to invoke tasty-bench with filters. The Concrete Steps
  section is updated accordingly.


## Decision Log

- Decision: Use `deriving anyclass (NFData)` on the data declarations in
  `Shibuya.Core.Types` rather than standalone `deriving instance` blocks.
  Rationale: The `shibuya-core` library already enables `DeriveAnyClass` and
  `DerivingStrategies` in its `default-extensions` (see `shibuya-core.cabal`), every
  affected type already has `deriving stock (... Generic)`, and the request the user
  phrased literally uses `deriving anyclass`. Putting the derivation on the declaration
  keeps the instance next to the type and avoids a second top-level syntactic form.
  Date: 2026-04-18.

- Decision: Add `deepseq` as a regular `build-depends` entry in the `library` stanza of
  `shibuya-core/shibuya-core.cabal` rather than gating it behind a cabal flag.
  Rationale: `deepseq` is a boot library that ships with every supported GHC, so adding
  it costs no external dependency and no build-time overhead. A cabal flag would force
  every downstream benchmark author to know about the flag and enable it — defeating
  the point of this change, which is "works out of the box". Date: 2026-04-18.

- Decision: For the `newtype MessageId`, use `deriving anyclass (NFData)` (via Generic)
  rather than `deriving newtype (NFData)`.
  Rationale: The two strategies produce operationally identical code for a single-field
  newtype over `Text` (which has its own `NFData` instance), but the anyclass form keeps
  all three public types following the same pattern, which makes the module easier to
  read and to extend. If a future profiling pass shows a difference we can revisit.
  Date: 2026-04-18.


## Outcomes & Retrospective

Completed 2026-04-18 across three commits on `master`:

1. `shibuya-core.cabal` gained a `deepseq ^>=1.5` library dependency and
   `Shibuya.Core.Types` now derives `NFData` for `MessageId`, `Cursor`, and
   `Envelope` via `deriving anyclass` atop the existing `Generic` instances.
2. `shibuya-core-bench/bench/Bench/Framework.hs` was updated to force
   `map (.envelope) msgs` in `createMockAdapter`, turning any future regression in
   the library's `NFData` instances into a compile error.
3. `CHANGELOG.md` got an `Unreleased` section announcing the addition.

Validation:

- `cabal build all` — succeeds with no new warnings.
- `cabal test shibuya-core-test` — 91 examples, 0 failures.
- `cabal bench shibuya-core-bench --benchmark-options='-p mock-adapter-100'` — all
  3 matching benchmarks pass, exercising the new instances on every run.
- Library-level REPL check (`rnf` on a fully populated `Envelope`) returns `()`
  with no orphan declarations.
- `rg 'NFData\s+(MessageId|Cursor|Envelope)'` against the source tree finds zero
  orphan declarations outside this plan file.

What was achieved vs. purpose: the stated "works out of the box" outcome is met.
Downstream benchmarks can import `Shibuya.Core` and immediately use `nfIO`, `nf`,
and `deepseq` on `MessageId`, `Cursor`, and `Envelope a` (where `a : NFData`)
without declaring any orphans.

Lessons learned:

- The plan's original Milestone 2 instruction (`msgs `deepseq` ...`) would not have
  typechecked because `Ingested` carries an `AckHandle` wrapping a function, and
  function types have no meaningful `NFData` instance. The fix — force the
  envelopes via `map (.envelope)` — is small and preserves the milestone's intent,
  but worth recording for anyone who later considers making `Ingested` deeply
  forceable. It probably cannot be without splitting the ack handle out of the
  forceable portion of the record.
- `cabal run <pkg>` is ambiguous when a package ships both an executable and a
  benchmark. Prefer `cabal bench <pkg> --benchmark-options='...'` for tasty-bench
  invocations.


## Context and Orientation

Shibuya is a Haskell library that provides a supervised queue-processing framework. The
repository is a cabal multi-package project rooted at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. The packages relevant to this
plan are:

- `shibuya-core/` — the core library. Its public message types live in
  `shibuya-core/src/Shibuya/Core/Types.hs` and are re-exported from
  `shibuya-core/src/Shibuya/Core.hs`.
- `shibuya-core-bench/` — a benchmark package that uses `tasty-bench` and imports
  `Control.DeepSeq (NFData, deepseq)`. It already depends on `deepseq`.
- `shibuya-pgmq-adapter-bench/` — another benchmark package that also depends on
  `deepseq`. It does not currently import Shibuya's core message types, so it is not
  the place that needs the new instances, but its presence confirms that Shibuya has
  multiple downstream benchmarks.

The three types that need `NFData` instances are defined in
`shibuya-core/src/Shibuya/Core/Types.hs`:

    newtype MessageId = MessageId {unMessageId :: Text}
      deriving stock (Eq, Ord, Show, Generic)
      deriving newtype (IsString)

    data Cursor
      = CursorInt !Int
      | CursorText !Text
      deriving stock (Eq, Ord, Show, Generic)

    data Envelope msg = Envelope
      { messageId :: !MessageId,
        cursor :: !(Maybe Cursor),
        partition :: !(Maybe Text),
        enqueuedAt :: !(Maybe UTCTime),
        traceContext :: !(Maybe TraceHeaders),
        payload :: !msg
      }
      deriving stock (Eq, Show, Functor, Generic)

All three already derive `Generic` (from `GHC.Generics`), which is the prerequisite for
`deriving anyclass (NFData)`. The `traceContext` field holds `[(ByteString, ByteString)]`
(alias `TraceHeaders`); lists and pairs of `ByteString` already have `NFData` instances
through `deepseq`, so no extra work is needed for that field.

Library metadata is in `shibuya-core/shibuya-core.cabal`. The `library` stanza lists
`default-extensions` that already include `DeriveAnyClass` and `DerivingStrategies`, and
a `build-depends` block that currently does **not** include `deepseq`. That block needs
one new line.

The user's build workflow (per `CLAUDE.md`) is:

    cabal build all
    cabal test shibuya-core-test
    nix fmt
    git add <files>
    git commit

A treefmt pre-commit hook runs Fourmolu on Haskell sources. The Fourmolu configuration
is in `fourmolu.yaml` (2-space indent, trailing commas, trailing import/export style).
Always run `nix fmt` before `git commit` so the hook does not reject the commit.


## Plan of Work

The work is small — three new derived instances, one new build-depends line, one
changelog entry, and a build/test cycle to prove nothing regressed. It is split into
three milestones so that each commit is independently verifiable.


### Milestone 1 — Add the instances in `shibuya-core`

At the end of this milestone, `Shibuya.Core.Types` exports `NFData` instances for
`MessageId`, `Cursor`, and `Envelope` (when the payload type is an `NFData`), and
`shibuya-core` builds cleanly. This is the substantive change.

Edits:

1. Open `shibuya-core/shibuya-core.cabal`. In the `library` stanza's `build-depends:`
   block (the one bounded by the `library` keyword and the next `test-suite` stanza),
   add a line:

        deepseq ^>=1.5,

   Place it in alphabetical order among the existing dependencies (between `containers`
   and `effectful`). Preserve the trailing comma style already used in that block. Use
   the `^>=1.5` bound because that is the major version shipped with the GHC this
   project targets (the cabal file declares `base ^>=4.21.0.0`, which corresponds to
   GHC 9.10, which ships `deepseq-1.5.*`).

2. Open `shibuya-core/src/Shibuya/Core/Types.hs`. Add a new import grouped with the
   existing imports, alphabetised by module name:

        import Control.DeepSeq (NFData)

   The existing imports are `Data.ByteString (ByteString)`, `Data.String (IsString)`,
   and `Shibuya.Prelude`. `Control.DeepSeq` sorts before all of them.

3. In the same file, extend each of the three data declarations with
   `deriving anyclass (NFData)`. The result should look like:

        newtype MessageId = MessageId {unMessageId :: Text}
          deriving stock (Eq, Ord, Show, Generic)
          deriving newtype (IsString)
          deriving anyclass (NFData)

        data Cursor
          = CursorInt !Int
          | CursorText !Text
          deriving stock (Eq, Ord, Show, Generic)
          deriving anyclass (NFData)

        data Envelope msg = Envelope
          { messageId :: !MessageId,
            cursor :: !(Maybe Cursor),
            partition :: !(Maybe Text),
            enqueuedAt :: !(Maybe UTCTime),
            traceContext :: !(Maybe TraceHeaders),
            payload :: !msg
          }
          deriving stock (Eq, Show, Functor, Generic)
          deriving anyclass (NFData)

   For the parameterised `Envelope msg`, `DeriveAnyClass` together with the `Generic`
   instance automatically produces `instance NFData msg => NFData (Envelope msg)`. No
   explicit constraint needs to be written.

4. Do not modify `Shibuya.Core` (the re-export module). `NFData` instances follow the
   type, so any module that already re-exports `MessageId`, `Cursor`, and `Envelope`
   automatically makes the new instance visible.

5. Run `nix fmt` from the repository root so Fourmolu can re-format the file if the
   derivation lines need adjustment, then rebuild:

        cabal build shibuya-core

   Expected result: the package compiles with no new warnings. If GHC reports
   `-Worphans` on any bench package, investigate there, not here — the library itself
   cannot produce an orphan warning for instances it declares alongside the type.

6. Commit with the trailer:

        Provide NFData instances for core message types

        Adds `NFData` instances for `MessageId`, `Cursor`, and `Envelope` directly in
        `Shibuya.Core.Types` so that benchmark authors no longer have to declare
        orphan instances in every benchmark module.

        ExecPlan: docs/plans/1-provide-nfdata-for-core-types.md


### Milestone 2 — Verify through the existing benchmark suite

At the end of this milestone we have concrete evidence that the new instances are
reachable: the `shibuya-core-bench` benchmark builds against the updated library and
runs at least one benchmark without any locally-added orphan declarations. Today there
are no orphan declarations for `MessageId`, `Cursor`, or `Envelope` inside
`shibuya-core-bench/` (verified with `rg 'instance NFData (MessageId|Cursor|Envelope)'
shibuya-core-bench`), so the job here is to (a) confirm the benchmark still builds
after the library change and (b) add a one-off NF-forcing benchmark that exercises the
library-provided instances so a regression would break the build.

Edits:

1. Confirm that no module in `shibuya-core-bench/` currently declares
   `instance NFData MessageId`, `instance NFData Cursor`, or `instance NFData Envelope`:

        rg -n 'NFData[[:space:]]+(MessageId|Cursor|Envelope)' shibuya-core-bench

   Expected output: no matches. If any matches appear, delete those orphan declarations
   — they are now redundant — and note the deletion in the Surprises & Discoveries
   section of this plan.

2. In `shibuya-core-bench/bench/Bench/Framework.hs`, the existing setup code in
   `wrapAsIngested` already constructs `Envelope BenchMessage` values. Add a
   one-line smoke test using the library-provided `NFData` so the instances are
   exercised in CI:

   - Near the top of the module, next to the existing `import Control.DeepSeq (NFData,
     deepseq)`, leave the import as-is — `deepseq` is already brought in.
   - Inside the `createMockAdapter` function, replace the current final line

            length msgs `deepseq` pure (length msgs)

     with

            map (.envelope) msgs `deepseq` pure (length msgs)

     This forces every `Envelope BenchMessage` in the list. Note: forcing the
     `Ingested` values directly does **not** work because `Ingested` contains an
     `AckHandle` that wraps a function, and functions have no useful `NFData` instance
     (see Surprises & Discoveries for 2026-04-18). Forcing the envelopes still
     exercises `NFData (Envelope _)`, `NFData MessageId`, and `NFData (Maybe Cursor)`
     — exactly the new library instances — so any future regression still turns into
     a compile-time error.

   Rationale: this keeps the benchmark meaningful (the number of messages is still what
   is returned), but makes the benchmark cover the library's new instances so any
   regression — for example, someone accidentally deleting `deriving anyclass (NFData)`
   — turns into a compile-time failure rather than a silent performance regression.

3. Build and smoke-test:

        cabal build shibuya-core-bench
        cabal bench shibuya-core-bench \
          --benchmark-options='--timeout 5 --stdev 1000 -p mock-adapter-100'

   Use `cabal bench` (not `cabal run`): the `shibuya-core-bench` package ships a
   separate `standalone-test` executable that `cabal run` resolves to by default.
   The `--timeout 5` and `--stdev 1000` flags let tasty-bench accept any timing
   variance within five seconds of measurement — they exist so we do not pay the full
   benchmark cost just to verify the change compiles and runs. The pattern
   `mock-adapter-100` also matches `mock-adapter-1000` and `mock-adapter-10000`; that
   is fine for a smoke test.

   Expected transcript (timings will vary):

        All
          framework-overhead
            adapter-creation
              mock-adapter-100:   OK
                14.6 μs ± 26 μs, 130 KB allocated, ...
              mock-adapter-1000:  OK
                167 μs ± 232 μs, 1.3 MB allocated, ...
              mock-adapter-10000: OK
                2.12 ms ± 3.6 ms, 14 MB allocated, ...

        All 3 tests passed (0.23s)

4. Commit with the trailer:

        Force NFData on Ingested list in mock-adapter benchmark

        Exercises the library-provided `NFData` instances for `MessageId`, `Cursor`,
        and `Envelope` so a regression in `Shibuya.Core.Types` surfaces as a compile
        error in `shibuya-core-bench`.

        ExecPlan: docs/plans/1-provide-nfdata-for-core-types.md


### Milestone 3 — Record the change in the changelog

At the end of this milestone, `CHANGELOG.md` has a new `Unreleased` section that
credits the new instances. This is a small but non-optional step: Shibuya 0.1.0.0 is
already on Hackage, so every API-visible addition needs to be announced.

Edits:

1. Open `CHANGELOG.md`. Insert a new section immediately below the top-level heading
   `# Changelog`:

        ## Unreleased

        ### Added

        - `shibuya-core`: `NFData` instances for `MessageId`, `Cursor`, and
          `Envelope a` (when `a` itself has an `NFData` instance). Benchmark authors
          no longer need to declare these as orphans.

   Leave the existing `## 0.1.0.0 — 2026-02-24` section untouched.

2. Commit with the trailer:

        Changelog: note added NFData instances

        ExecPlan: docs/plans/1-provide-nfdata-for-core-types.md


## Concrete Steps

All commands below are run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

1. Check the tree is clean:

        git status

   Expected: `nothing to commit, working tree clean`. If the tree is dirty, commit or
   stash existing work before starting.

2. Apply the Milestone 1 edits (see above).

3. Format and rebuild:

        nix fmt
        cabal build shibuya-core

   Expected output ends with:

        Building library for shibuya-core-0.1.0.0..
        ... (no warnings that mention Orphans or NFData)

4. Run the test suite for the library to prove nothing regressed:

        cabal test shibuya-core-test

   Expected: all tests pass. There are no tests that assert anything about `NFData`,
   so the only thing we are checking here is that the new instances do not change any
   existing type-class resolution.

5. Stage and commit Milestone 1:

        git add shibuya-core/shibuya-core.cabal shibuya-core/src/Shibuya/Core/Types.hs
        git commit

   Paste the commit message from Milestone 1 step 6, including the `ExecPlan:` trailer.

6. Apply the Milestone 2 edits (see above).

7. Build and smoke-test the benchmark:

        cabal build shibuya-core-bench
        cabal bench shibuya-core-bench \
          --benchmark-options='--timeout 5 --stdev 1000 -p mock-adapter-100'

   Expected: the three `mock-adapter-*` benchmarks run and pass. Using `cabal bench`
   is important — `cabal run shibuya-core-bench` resolves to the package's
   `standalone-test` executable instead.

8. Format, stage, commit:

        nix fmt
        git add shibuya-core-bench/bench/Bench/Framework.hs
        git commit

   Paste the commit message from Milestone 2 step 4.

9. Apply the Milestone 3 edits, then:

        git add CHANGELOG.md
        git commit

   Paste the commit message from Milestone 3 step 2.

10. Final verification:

        cabal build all

    Expected: every package in the project builds with no new warnings.


## Validation and Acceptance

Acceptance is observable behavior, not just a successful build. Three checks:

1. Library-level check — a user can evaluate a Shibuya message to normal form without
   declaring any orphan. Save the following snippet to a scratch file and run it with
   `cabal repl shibuya-core`:

        ghci> :set -XOverloadedStrings
        ghci> import Shibuya.Core
        ghci> import Control.DeepSeq (rnf)
        ghci> let e = Envelope (MessageId "m1") (Just (CursorInt 7)) Nothing Nothing Nothing ("hello" :: String)
        ghci> rnf e
        ()

    Before this change, the final line would fail with
    `No instance for 'NFData (Envelope String)'`. After this change it returns `()`.

2. Benchmark-level check — the existing benchmark suite compiles and runs without any
   orphan `NFData` declarations for `MessageId`, `Cursor`, or `Envelope`. Running

        rg -n 'NFData[[:space:]]+(MessageId|Cursor|Envelope)' shibuya-core-bench shibuya-pgmq-adapter-bench

    must print nothing.

3. Test-level check — the full core test suite still passes:

        cabal test shibuya-core-test

    Expected: all tests pass. No test should need to change.

If any of the three checks fails, do not proceed to the next milestone until the
underlying cause is recorded in the Surprises & Discoveries section and addressed.


## Idempotence and Recovery

Every step in this plan is additive: new derivations, one new import, one new
build-depends line, one new changelog section, and a one-character tweak to a
benchmark module. Re-running `cabal build` and `cabal test` is always safe.

If the build fails after Milestone 1 because of a cabal version-bound mismatch on
`deepseq` (for example, if the freeze file `cabal.project.freeze` pins a version
outside `^>=1.5`), loosen the bound to `>=1.4 && <1.6` and note the change in the
Decision Log.

If `nix fmt` re-formats the file in a way that conflicts with the derivation layout
shown in Milestone 1, accept Fourmolu's output — it is authoritative for this project.

If a commit is rejected by the treefmt pre-commit hook:
1. Re-run `nix fmt`.
2. `git add` the re-formatted files.
3. `git commit` again. Do **not** use `--amend`, because the hook aborted before the
   commit was created, so there is nothing to amend.

To roll back any single milestone, run `git reset --hard HEAD~1`. To roll back all
three, `git reset --hard HEAD~3`. Neither loses work outside this plan because every
other file in the tree is untouched.


## Interfaces and Dependencies

Libraries used:

- `deepseq` (new dependency of `shibuya-core` library). Provides the `NFData` type class
  and the `rnf` method. Boot library; no external download needed.
- `GHC.Generics` (already imported via `Shibuya.Prelude`). Provides the `Generic`
  constraint that `DeriveAnyClass` uses to generate the `NFData` method body.

Types and instances that must exist at the end of Milestone 1, in
`shibuya-core/src/Shibuya/Core/Types.hs`:

    instance NFData MessageId
    instance NFData Cursor
    instance NFData a => NFData (Envelope a)

These instances are generated by `deriving anyclass (NFData)` on the corresponding data
declarations. They must be visible wherever `MessageId`, `Cursor`, or `Envelope` is in
scope — that is, anywhere that imports `Shibuya.Core.Types`, `Shibuya.Core`, or any
module that re-exports those names.

Full module paths touched:

- `shibuya-core/shibuya-core.cabal` — add `deepseq` to library `build-depends`.
- `shibuya-core/src/Shibuya/Core/Types.hs` — add import, add three `deriving anyclass`
  clauses.
- `shibuya-core-bench/bench/Bench/Framework.hs` — switch the final `deepseq` of
  `createMockAdapter` to force the message list rather than its length.
- `CHANGELOG.md` — add an `Unreleased` section.

No changes are required to `Shibuya.Core`, `Shibuya.App`, `Shibuya.Adapter`, or any
other public module.
