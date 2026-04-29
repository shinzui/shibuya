# Add Attempt newtype and `attempt` field on Envelope

MasterPlan: docs/masterplans/1-exponential-backoff-for-retries.md
Intention: intention_01kqbspdwse4tv03dbkbyt1cmg

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, every `Envelope` value passing through Shibuya carries an optional
"this is delivery N of this message" counter. A handler can read
`ingested.envelope.attempt` and learn whether it is being invoked for the first time
(`Just (Attempt 0)`), for the first retry (`Just (Attempt 1)`), and so on. Adapters
that cannot track redeliveries set the field to `Nothing`.

Today this counter is missing entirely. There is no way for a handler to know it is on
its third attempt versus its first. The framework's own `AckRetry` mechanism (defined
in `shibuya-core/src/Shibuya/Core/Ack.hs`) requires the handler to compute a delay,
but the handler has no input to compute it from. This plan provides that input.

A reader can verify the change by:

1. Building `cabal build all` from the repo root and observing it succeeds.
2. Running `cabal test shibuya-core-test` and observing all tests pass — including
   a new test in `shibuya-core/test/Shibuya/Core/TypesSpec.hs` that asserts the field
   round-trips through `fmap`.
3. Opening a REPL and writing
   ``Envelope { messageId = "x", cursor = Nothing, partition = Nothing, enqueuedAt =
   Nothing, traceContext = Nothing, attempt = Just (Attempt 2), payload = "hi" }``
   and observing it typechecks.

This plan does *not* implement the backoff policy module (that is the next plan in
the same MasterPlan, `docs/plans/6-add-backoff-policy-module.md`). It does *not*
populate the field from any specific queue's delivery counter (that is
`docs/plans/7-populate-attempt-from-pgmq-readcount.md`). It is the foundation that
unblocks both.


## Progress

- [x] Milestone 1 — Add the `Attempt` newtype to
      `shibuya-core/src/Shibuya/Core/Types.hs`. Includes derivation of
      `Eq`, `Ord`, `Show`, `Generic`, `NFData`, plus the numeric newtype-derived
      instances needed for arithmetic on the inner `Word`. Update the export list
      and add the type's own unit-test coverage in
      `shibuya-core/test/Shibuya/Core/TypesSpec.hs`. *(2026-04-29)*
- [x] Milestone 2 — Add the `attempt :: !(Maybe Attempt)` field to the `Envelope`
      record (also in `Types.hs`). Update every Envelope construction site in this
      repository so the build stays green: `shibuya-core/test/Shibuya/Core/TypesSpec.hs`,
      `shibuya-core/test/Shibuya/RunnerSpec.hs`,
      `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs`,
      `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`,
      `shibuya-example/app/Main.hs`, plus the four bench sites surfaced in
      Surprises & Discoveries (`shibuya-core-bench/bench/Bench/{Framework,Handler,Concurrency}.hs`
      and `shibuya-core-bench/bench/Test/StandaloneTest.hs`). Each of those
      sites passes `attempt = Nothing` because they construct mock messages
      with no delivery history. *(2026-04-29)*
- [ ] Milestone 3 — Re-export `Attempt (..)` from `shibuya-core/src/Shibuya/Core.hs`.
      Add an entry to `shibuya-core/CHANGELOG.md` under a fresh `Unreleased` section
      noting the breaking change to `Envelope`'s shape and bumping the planned
      version to `0.4.0.0` (a major bump because adding a record field breaks all
      direct constructions).


## Surprises & Discoveries

- The plan's M2 enumeration of construction sites missed the
  `shibuya-core-bench/` package. A repo-wide grep for `Envelope$\|Envelope {`
  surfaced four additional sites:
  `shibuya-core-bench/bench/Bench/Framework.hs:150`,
  `shibuya-core-bench/bench/Bench/Handler.hs:127`,
  `shibuya-core-bench/bench/Bench/Concurrency.hs:223`, and
  `shibuya-core-bench/bench/Test/StandaloneTest.hs:111`. Each was updated to
  pass `attempt = Nothing` for the same reason as the test helpers. Date:
  2026-04-29.

- The plan's M1 test snippet wrote `unAttempt (minBound :: Attempt)` as a
  function call, but `NoFieldSelectors` is enabled in `shibuya-core.cabal`'s
  `default-extensions`, so field accessors are not in scope. Replaced with
  record-dot syntax: `(minBound :: Attempt).unAttempt`. Date: 2026-04-29.


## Decision Log

- Decision: Use `Word`, not `Int` or `Natural`, as the inner type of `Attempt`.
  Rationale: `Word` is fixed-size and unboxed-friendly, matching the perf
  sensibility of the rest of the core types. `Natural` would pull in GMP and is
  overkill for a counter that will never exceed 32 bits in practice (pgmq's
  `readCount` is `Int64` but the realistic ceiling is `maxRetries`, typically
  single digits). `Int` would allow negative values, which are meaningless.
  Date: 2026-04-28.

- Decision: Add the field at the *end* of the existing `Envelope` field list
  rather than inserting it between existing fields.
  Rationale: Although `OverloadedRecordDot` makes positional ordering invisible
  to most readers, treefmt-formatted Haskell preserves source order, and a
  diff that touches only the trailing field is easier to review.
  Date: 2026-04-28.

- Decision: Initialize the field to `Nothing` in every existing in-tree
  construction site rather than threading delivery-history through the test
  helpers.
  Rationale: The test helpers in this plan model fresh deliveries with no prior
  history; `Nothing` is the correct value. Tests that explicitly want to
  exercise retry paths can override the field at construction.
  Date: 2026-04-28.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) is the
home of the `shibuya-core` library. The library is organized so that everything in
`shibuya-core/src/Shibuya/Core/` is a stable identity-and-metadata layer with no
behavior — just types. The relevant modules:

- `shibuya-core/src/Shibuya/Core/Types.hs` defines `MessageId`, `Cursor`,
  `TraceHeaders`, and `Envelope`. `Envelope` currently has six fields:
  `messageId`, `cursor`, `partition`, `enqueuedAt`, `traceContext`, `payload`.
- `shibuya-core/src/Shibuya/Core/Ingested.hs` defines `Ingested es msg`, which
  wraps `Envelope msg` together with an `AckHandle es` and an optional `Lease es`.
  Handlers receive `Ingested`, not bare `Envelope`.
- `shibuya-core/src/Shibuya/Core/Ack.hs` defines `AckDecision` and `RetryDelay`.
  These are mechanism-free types: a handler returns `AckRetry (RetryDelay 30)` to
  ask for a 30-second retry, and the adapter does whatever queue-specific thing
  that means.
- `shibuya-core/src/Shibuya/Core.hs` is the public re-export hub. Anything added
  to `Core/Types.hs` that should be user-visible must be re-exported here.

The repository builds with `cabal build all` from the repo root; tests run with
`cabal test shibuya-core-test`. The `shibuya-example` package
(`shibuya-example/app/Main.hs`) is an executable that exercises the public API and
must continue to build.

A "newtype" in Haskell is a single-constructor wrapper around an existing type
that has zero runtime overhead. Newtypes are how this codebase distinguishes
identifier types: `MessageId` wraps `Text`, `RetryDelay` wraps `NominalDiffTime`.

`OverloadedRecordDot` is a GHC extension already enabled by default in this
package (see `default-extensions` in `shibuya-core/shibuya-core.cabal`). It lets
you write `env.attempt` instead of `attempt env`. Field selectors are *not*
generated (`NoFieldSelectors` is enabled), so to access fields you must use
either record-dot syntax, the `generic-lens` `#field` labels, or pattern matching.

`NFData` is the type class from the `deepseq` package whose `rnf` method forces
a value to normal form. The existing core types already derive it via
`deriving anyclass (NFData)` and `DeriveAnyClass`. Plan 1
(`docs/plans/1-provide-nfdata-for-core-types.md`) explains why.


## Plan of Work


### Milestone 1: Define the `Attempt` newtype

Open `shibuya-core/src/Shibuya/Core/Types.hs`. The existing module exports
`MessageId`, `Cursor`, `Envelope`, `TraceHeaders`. Add a new export:

    -- * Delivery Attempt
    Attempt (..),

Add the type definition near the top of the module (after `MessageId`,
before `Cursor` is fine — group it with the identity-style newtypes):

    -- | Zero-indexed delivery attempt count.
    -- 0 means first delivery; 1 means first retry; and so on.
    -- Adapters that cannot track redeliveries report 'Nothing' on the envelope.
    newtype Attempt = Attempt {unAttempt :: Word}
      deriving stock (Eq, Ord, Show, Generic)
      deriving newtype (Num, Real, Enum, Integral, Bounded)
      deriving anyclass (NFData)

The numeric-class derivations (`Num`, `Real`, `Enum`, `Integral`, `Bounded`)
are pulled directly from the wrapped `Word` so callers can write
`Attempt 2 + 1` and `fromIntegral (Attempt n)` without unwrapping. The newtype
gives them domain meaning without giving up arithmetic ergonomics.

Add a unit-test stanza to `shibuya-core/test/Shibuya/Core/TypesSpec.hs`
parallel to the existing `MessageId` describe-block:

    describe "Attempt" $ do
      it "supports Eq" $ do
        Attempt 0 `shouldBe` Attempt 0
        Attempt 0 `shouldNotBe` Attempt 1

      it "supports Ord for sequencing retries" $ do
        Attempt 0 `compare` Attempt 1 `shouldBe` LT
        Attempt 5 `compare` Attempt 5 `shouldBe` EQ
        Attempt 9 `compare` Attempt 1 `shouldBe` GT

      it "supports Num so retries can be incremented" $ do
        Attempt 0 + 1 `shouldBe` Attempt 1
        Attempt 4 + 1 `shouldBe` Attempt 5

      it "Bounded reflects the underlying Word" $ do
        unAttempt (minBound :: Attempt) `shouldBe` 0

The import line needs `Attempt (..)` added.

Run `cabal build shibuya-core` and `cabal test shibuya-core-test` to confirm
the new type compiles and the new tests pass.

Acceptance for M1: build is clean; `cabal test shibuya-core-test 2>&1 | tail -20`
shows the new "Attempt" describe-block in the output and all assertions pass.


### Milestone 2: Add the `attempt` field on Envelope

In the same file `shibuya-core/src/Shibuya/Core/Types.hs`, modify the `Envelope`
record. The current shape is:

    data Envelope msg = Envelope
      { messageId    :: !MessageId
      , cursor       :: !(Maybe Cursor)
      , partition    :: !(Maybe Text)
      , enqueuedAt   :: !(Maybe UTCTime)
      , traceContext :: !(Maybe TraceHeaders)
      , payload      :: !msg
      }

Add `attempt` as the second-to-last field (immediately before `payload`):

    data Envelope msg = Envelope
      { messageId    :: !MessageId
      , cursor       :: !(Maybe Cursor)
      , partition    :: !(Maybe Text)
      , enqueuedAt   :: !(Maybe UTCTime)
      , traceContext :: !(Maybe TraceHeaders)
      , -- | Optional zero-indexed delivery counter.
        -- 'Just (Attempt 0)' on first delivery; 'Nothing' if the adapter
        -- does not track redeliveries (e.g., Kafka).
        attempt    :: !(Maybe Attempt)
      , payload      :: !msg
      }

Run `nix fmt` after editing — treefmt will reorder/whitespace-normalize.

Now update every Envelope construction site in this repository. The sites
were located by searching for `Envelope\b` and `Envelope {` across both the
`shibuya-core` and `shibuya-example` packages. They are:

1. `shibuya-core/test/Shibuya/Core/TypesSpec.hs` — the `testEnvelope` helper at
   the bottom of the file. Add `attempt = Nothing,` between
   `traceContext = Nothing,` and `payload = msg`.

2. `shibuya-core/test/Shibuya/RunnerSpec.hs` — two construction sites at
   approximately lines 202 and 225. Each builds a test envelope; add
   `attempt = Nothing,` to each.

3. `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` — two sites at
   approximately lines 850 and 872 (in the helpers `createTestMessages` and
   `createSingleMessage`). Add `attempt = Nothing,` to each.

4. `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs` — one site at
   approximately line 66. Add `attempt = Nothing,`.

5. `shibuya-example/app/Main.hs` — one site at line 72 in the `mkIngested`
   helper. Add `attempt = Nothing,`.

Verify by running, from the repo root:

    cabal build all
    cabal test shibuya-core-test

Both must succeed. The `shibuya-example` does not have a test suite but the
build covers it; `cabal run shibuya-example` is unnecessary for this milestone.

Add a small property test to `shibuya-core/test/Shibuya/Core/TypesSpec.hs`
inside the existing `describe "Envelope"` block:

    it "preserves attempt through fmap" $ do
      let env = (testEnvelope (1 :: Int)) {attempt = Just (Attempt 3)}
          mapped = fmap show env
      mapped.attempt `shouldBe` Just (Attempt 3)

Acceptance for M2: `cabal build all` succeeds; `cabal test shibuya-core-test`
passes; the new "preserves attempt through fmap" assertion appears in the test
output.


### Milestone 3: Re-export and CHANGELOG

Open `shibuya-core/src/Shibuya/Core.hs`. The export list groups exports by
section. Find the `-- * Message Types` section, which currently exports:

    MessageId (..),
    Cursor (..),
    Envelope (..),

Add `Attempt (..),` to the same section. Update the corresponding import:

    import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))

becomes:

    import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), MessageId (..))

Open `shibuya-core/CHANGELOG.md`. If there is no `## Unreleased` section, add
one at the top (between the title and the most recent versioned section). Add
an entry like:

    ## Unreleased

    ### Breaking changes

    - `Envelope` gained an `attempt :: !(Maybe Attempt)` field carrying the
      adapter's delivery counter (zero-indexed; 'Nothing' if unknown). Direct
      constructions of `Envelope` must add the field. The new `Attempt`
      newtype is exported from `Shibuya.Core` and `Shibuya.Core.Types`.

Bump the planned next version. Open `shibuya-core/shibuya-core.cabal` and
note the current `version: 0.3.0.0`. The breaking change requires a major
bump. Record this intent in CHANGELOG by adding under the same `Unreleased`
section:

    Planned next release: 0.4.0.0 (major — breaks direct `Envelope` construction).

Do *not* bump the cabal `version` field in this milestone. The bump happens at
release time as part of EP-4 (the demonstration) or whenever the maintainer
cuts the release; landing it now would risk creating a half-released state if
later milestones in the MasterPlan churn the API further.

Run, from the repo root:

    nix fmt
    cabal build all
    cabal test shibuya-core-test

All must succeed.

Acceptance for M3: `Shibuya.Core` exports `Attempt(..)`; `Shibuya.Core.Types`
exports `Attempt(..)`; CHANGELOG mentions both the field and the planned
0.4.0.0 release.


## Concrete Steps

From the repo root `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`:

    cabal build all
    cabal test shibuya-core-test
    nix fmt

After all three milestones, the canonical verification sequence is:

    cabal clean
    cabal build all
    cabal test shibuya-core-test --test-show-details=direct

Expected tail of `cabal test` output:

    Finished in 0.04 seconds
    NN examples, 0 failures

Where `NN` is the existing test count plus four new assertions (3 in the new
`Attempt` block, 1 added to `Envelope`).


## Validation and Acceptance

A reader who has only this plan and the working tree can verify the change by:

1. Running `cabal build all` and observing it succeeds with no `-Wall`
   warnings related to `Envelope`.
2. Running `cabal test shibuya-core-test` and confirming the new assertions
   listed in the milestones appear and pass.
3. Opening `ghci` (e.g., via `cabal repl shibuya-core`) and entering:

       :set -XOverloadedStrings
       import Shibuya.Core.Types
       let e = Envelope (MessageId "x") Nothing Nothing Nothing Nothing (Just (Attempt 2)) "hello"
       e.attempt

   Expected output:

       Just (Attempt {unAttempt = 2})

4. Confirming the haddock for the new field renders by running `cabal haddock
   shibuya-core` and viewing the generated HTML at the path it prints.

The plan is "done" when all three milestones' acceptance criteria are met.


## Idempotence and Recovery

Each step in this plan is idempotent — re-running `nix fmt`, `cabal build`,
or `cabal test` is safe. If a milestone's edits land partially (for example,
the `Attempt` newtype is added but a construction site is missed), `cabal
build all` will report the missing field with a precise file:line. The
remaining sites can then be patched.

To roll back: `git restore` on the affected files (no schema or external
state is touched).


## Interfaces and Dependencies

This plan introduces no new external dependencies. `Word` is in `Prelude`;
`NFData` is already a transitive dependency via `deepseq`.

At the end of this plan, the following are visible to downstream users:

In `shibuya-core/src/Shibuya/Core/Types.hs`:

    newtype Attempt = Attempt { unAttempt :: Word }

    data Envelope msg = Envelope
      { messageId    :: !MessageId
      , cursor       :: !(Maybe Cursor)
      , partition    :: !(Maybe Text)
      , enqueuedAt   :: !(Maybe UTCTime)
      , traceContext :: !(Maybe TraceHeaders)
      , attempt      :: !(Maybe Attempt)
      , payload      :: !msg
      }

Re-exported from `Shibuya.Core` so that `import Shibuya.Core (Attempt(..),
Envelope(..))` works.
