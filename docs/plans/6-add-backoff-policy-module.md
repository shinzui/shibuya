# Add Shibuya.Core.Retry with BackoffPolicy and exponentialBackoff helpers

MasterPlan: docs/masterplans/1-exponential-backoff-for-retries.md
Intention: intention_01kqbspdwse4tv03dbkbyt1cmg

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, a Shibuya handler that wants to retry a failed message with an
exponentially-growing, jittered delay can write one line:

    handler ingested = do
      result <- tryProcess ingested.envelope.payload
      case result of
        Right () -> pure AckOk
        Left _  -> retryWithBackoff defaultBackoffPolicy ingested.envelope

Without this plan, the handler must compute the delay itself. The Shibuya runtime
gives it `ingested.envelope.attempt :: Maybe Attempt` (added in the prerequisite
plan `docs/plans/5-add-attempt-to-envelope.md`) but no helper for turning that into
a `RetryDelay`. Every consumer of the framework would have to reinvent
`base * factor^attempt`, plus jitter, plus max-delay clamping.

This plan adds a new module `Shibuya.Core.Retry` containing:

- A pure record `BackoffPolicy { base, factor, maxDelay, jitter }`.
- A `Jitter` sum: `NoJitter`, `FullJitter`, `EqualJitter`.
- A pure evaluator `exponentialBackoffPure :: BackoffPolicy -> Attempt -> Double ->
  RetryDelay` taking a sample in `[0,1)`, suitable for property tests.
- An effectful evaluator `exponentialBackoff :: (IOE :> es) => BackoffPolicy ->
  Attempt -> Eff es RetryDelay` that samples randomness and calls the pure variant.
- A convenience wrapper `retryWithBackoff :: (IOE :> es) => BackoffPolicy ->
  Envelope msg -> Eff es AckDecision` that reads `envelope.attempt`, computes the
  delay, and returns `AckRetry`.
- A `defaultBackoffPolicy` (1 second base, factor 2, max 5 minutes, FullJitter)
  matching AWS's published recommendation.

A reader can verify the change by:

1. Building `cabal build shibuya-core` and observing it succeeds.
2. Running `cabal test shibuya-core-test` and seeing the new `RetrySpec` test
   group pass — covering monotonicity, max-delay clamping, jitter bounds, and
   the boundary cases for `Attempt 0` and `Attempt maxBound`.
3. Importing the module in `ghci`:

       :set -XOverloadedRecordDot
       import Shibuya.Core.Retry
       import Shibuya.Core.Types (Attempt(..))
       exponentialBackoffPure defaultBackoffPolicy (Attempt 3) 0.5

   and observing it returns a `RetryDelay` whose seconds are in the expected
   range.

This plan is independent of `docs/plans/7-populate-attempt-from-pgmq-readcount.md`
and `docs/plans/8-demonstrate-backoff-end-to-end.md`. It hard-depends on
`docs/plans/5-add-attempt-to-envelope.md` because `retryWithBackoff` reads
`envelope.attempt`.


## Progress

- [ ] Milestone 1 — Add the new module `shibuya-core/src/Shibuya/Core/Retry.hs`
      with `BackoffPolicy`, `Jitter`, `defaultBackoffPolicy`, and the pure
      evaluator `exponentialBackoffPure`. List the module in
      `shibuya-core/shibuya-core.cabal` `exposed-modules`.
- [ ] Milestone 2 — Add the effectful `exponentialBackoff` (uses `IOE` to draw a
      sample from `System.Random`), and the convenience `retryWithBackoff`.
      Add `random` to the build-depends if not already present.
- [ ] Milestone 3 — Add `shibuya-core/test/Shibuya/Core/RetrySpec.hs` with
      property and unit tests. Wire it into `Main.hs` and the test cabal stanza.
      Update the CHANGELOG `Unreleased` section to mention the new module.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Use the `random` package (which ships with GHC) rather than
  `mwc-random` or `splitmix` directly.
  Rationale: `random` is already a transitive dependency of the existing
  `nqe`/`uuid`/`hspec` chain. Pulling in an additional RNG package for a
  single `[0,1)` draw is unjustified. `System.Random.randomRIO (0, 1)` (in
  `IO`) is sufficient. Performance is not critical — this is called at most
  once per failed delivery, on the order of seconds apart.
  Date: 2026-04-28.

- Decision: Treat `Nothing` `attempt` as `Attempt 0` inside `retryWithBackoff`.
  Rationale: A handler should not have to write `case envelope.attempt of ...`
  for the common case. `Attempt 0` produces `delay = base * factor^0 = base`,
  which is the minimum interval — a safe and intuitive default for adapters
  that don't track delivery counts.
  Date: 2026-04-28.

- Decision: `BackoffPolicy.factor` is a `Double`, not an `Int`.
  Rationale: AWS's published recommendation uses non-integer growth factors
  (e.g., `1.5`) for less aggressive ramp-up. Forcing `Int` would force users
  to choose `base = 100ms, factor = 2` over `base = 1s, factor = 1.5` even
  when the latter is what they want. The pure evaluator does the math in
  `Double` and converts to `NominalDiffTime` at the boundary.
  Date: 2026-04-28.

- Decision: The pure variant's sample type is `Double` constrained to `[0,1)`,
  not `Word32` or some seeded-RNG type.
  Rationale: Tests can pick exact representative samples (`0.0`, `0.5`,
  `0.999`). A seeded RNG would force tests to know the seed-to-sample
  mapping, which is not stable across `random` library versions.
  Date: 2026-04-28.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) hosts
the `shibuya-core` library. The relevant existing modules:

- `shibuya-core/src/Shibuya/Core/Types.hs` defines `Attempt` (a newtype around
  `Word`) and `Envelope msg`. The `attempt :: !(Maybe Attempt)` field on
  `Envelope` is the input this plan reads. The prerequisite plan
  `docs/plans/5-add-attempt-to-envelope.md` introduces both.
- `shibuya-core/src/Shibuya/Core/Ack.hs` defines `RetryDelay` (a newtype around
  `NominalDiffTime`) and `AckDecision`. The output of this plan is `RetryDelay`
  and `AckDecision`.
- `shibuya-core/src/Shibuya/Core.hs` is the public re-export hub. New types
  intended for application authors must be re-exported here.

The package uses the `effectful` effect system. The convention is:

    someFunction :: (IOE :> es) => Arg -> Eff es Result

`IOE :> es` means "this effect stack contains `IOE`," which is required to
lift `IO` operations like `randomRIO`. Every test in `shibuya-core-test` runs
under `runEff`, which provides `IOE`.

The package's default extensions (see `shibuya-core/shibuya-core.cabal`)
include `OverloadedRecordDot`, `OverloadedStrings`, `DerivingStrategies`, and
`DeriveAnyClass`. Use `deriving stock` and `deriving newtype` explicitly.

Tests use HSpec. The test entry point is
`shibuya-core/test/Main.hs`; new spec modules must be listed in both
`Main.hs` (where `hspec $ do specGroup ...` collects them) and the cabal
test stanza's `other-modules`. See existing examples like
`Shibuya.Core.AckSpec` or `Shibuya.Core.TypesSpec` for the pattern.

`treefmt` runs as a pre-commit hook. Always run `nix fmt` before staging
edits.


## Plan of Work


### Milestone 1: Pure backoff policy and evaluator

Create a new file `shibuya-core/src/Shibuya/Core/Retry.hs`. The module
exposes the policy types and the pure evaluator:

    -- | Exponential backoff policy and pure evaluator.
    --
    -- Handlers compute a 'RetryDelay' from a 'BackoffPolicy' and the current
    -- delivery 'Attempt'. The pure evaluator takes a jitter sample in [0,1)
    -- and is suitable for property tests; the effectful 'exponentialBackoff'
    -- (defined in the same module) samples randomness via 'IOE'.
    module Shibuya.Core.Retry
      ( -- * Policy
        BackoffPolicy (..),
        Jitter (..),
        defaultBackoffPolicy,

        -- * Pure evaluator
        exponentialBackoffPure,

        -- * Effectful evaluator
        exponentialBackoff,

        -- * Handler convenience
        retryWithBackoff,
      )
    where

The data definitions:

    -- | Strategy for adding randomness to backoff delays.
    -- Jitter prevents thundering herds when many messages fail simultaneously.
    --
    -- See <https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/>.
    data Jitter
      = -- | No randomness; delay is deterministic.
        NoJitter
      | -- | Delay is uniform in @[0, baseExp]@ where @baseExp@ is
        -- @min maxDelay (base * factor^attempt)@.
        FullJitter
      | -- | Delay is @baseExp / 2 + uniform(0, baseExp / 2)@.
        EqualJitter
      deriving stock (Eq, Show, Generic)

    -- | Configuration for exponential backoff with optional jitter.
    data BackoffPolicy = BackoffPolicy
      { -- | Base delay applied at attempt 0 (before jitter).
        base :: !NominalDiffTime,
        -- | Multiplicative growth factor between attempts. Typically 2.0.
        factor :: !Double,
        -- | Upper bound on the computed delay before jitter.
        -- Prevents arbitrarily long retries far in the future.
        maxDelay :: !NominalDiffTime,
        -- | Jitter strategy.
        jitter :: !Jitter
      }
      deriving stock (Eq, Show, Generic)

    -- | Sensible defaults: 1 s base, factor 2, max 5 min, full jitter.
    --
    -- This matches AWS's published recommendation. With these defaults:
    --
    -- - Attempt 0: random delay in [0, 1) s
    -- - Attempt 1: random delay in [0, 2) s
    -- - Attempt 2: random delay in [0, 4) s
    -- - ...
    -- - Attempt 8 onwards: random delay in [0, 256) s, capped at [0, 300) s
    defaultBackoffPolicy :: BackoffPolicy
    defaultBackoffPolicy =
      BackoffPolicy
        { base = 1, -- 1 second
          factor = 2.0,
          maxDelay = 300, -- 5 minutes
          jitter = FullJitter
        }

The pure evaluator:

    -- | Compute a retry delay from a policy, an attempt count, and a jitter
    -- sample in @[0, 1)@.
    --
    -- The sample is consumed only when the policy's 'jitter' is not 'NoJitter';
    -- callers passing @0.0@ to a 'NoJitter' policy will see deterministic output.
    exponentialBackoffPure ::
      BackoffPolicy ->
      Attempt ->
      -- | Jitter sample in @[0, 1)@. Ignored when 'jitter' = 'NoJitter'.
      Double ->
      RetryDelay
    exponentialBackoffPure policy (Attempt n) sample =
      RetryDelay (secondsToNominalDiffTime (realToFrac jittered))
      where
        baseSec :: Double
        baseSec = realToFrac (nominalDiffTimeToSeconds policy.base)

        maxSec :: Double
        maxSec = realToFrac (nominalDiffTimeToSeconds policy.maxDelay)

        -- Pre-jitter exponential, clamped to maxDelay
        baseExp :: Double
        baseExp = min maxSec (baseSec * policy.factor ** fromIntegral n)

        clampedSample :: Double
        clampedSample = max 0 (min 0.999999 sample)

        jittered :: Double
        jittered = case policy.jitter of
          NoJitter -> baseExp
          FullJitter -> baseExp * clampedSample
          EqualJitter -> baseExp / 2 + (baseExp / 2) * clampedSample

The required imports:

    import Data.Time (NominalDiffTime, nominalDiffTimeToSeconds, secondsToNominalDiffTime)
    import GHC.Generics (Generic)
    import Shibuya.Core.Ack (RetryDelay (..))
    import Shibuya.Core.Types (Attempt (..))

Add the module to `shibuya-core/shibuya-core.cabal` under `exposed-modules`,
in alphabetical position (after `Shibuya.Core.Lease`, before
`Shibuya.Core.Types`):

    Shibuya.Core.Retry

Run `nix fmt && cabal build shibuya-core`. Both must succeed.

Acceptance for M1: the module compiles; `cabal repl shibuya-core` can import
`Shibuya.Core.Retry` and evaluate `exponentialBackoffPure
defaultBackoffPolicy (Attempt 3) 0.5` to a `RetryDelay`.


### Milestone 2: Effectful evaluator and handler convenience

Extend `shibuya-core/src/Shibuya/Core/Retry.hs` with:

    -- | Compute a retry delay by sampling jitter from 'IO'.
    --
    -- Equivalent to 'exponentialBackoffPure' with a fresh sample drawn
    -- via 'System.Random.randomRIO' on each call.
    exponentialBackoff ::
      (IOE :> es) =>
      BackoffPolicy ->
      Attempt ->
      Eff es RetryDelay
    exponentialBackoff policy attempt = do
      sample <- liftIO (Random.randomRIO (0.0 :: Double, 1.0))
      pure (exponentialBackoffPure policy attempt sample)

    -- | One-line helper for the common case: read 'envelope.attempt',
    -- compute a backoff delay, and return 'AckRetry'.
    --
    -- Treats 'Nothing' attempt as 'Attempt 0' (first delivery).
    retryWithBackoff ::
      (IOE :> es) =>
      BackoffPolicy ->
      Envelope msg ->
      Eff es AckDecision
    retryWithBackoff policy envelope = do
      let attempt = fromMaybe (Attempt 0) envelope.attempt
      delay <- exponentialBackoff policy attempt
      pure (AckRetry delay)

Required additional imports:

    import Data.Maybe (fromMaybe)
    import Effectful (Eff, IOE, liftIO, (:>))
    import Shibuya.Core.Ack (AckDecision (..))
    import Shibuya.Core.Types (Envelope (..))
    import System.Random qualified as Random

Add `random ^>=1.2` to the `library`'s `build-depends` in
`shibuya-core/shibuya-core.cabal`. Verify `cabal build shibuya-core` resolves
the bound — `random` ships with GHC, so this should be a no-op for the
solver. If a stricter bound is needed, run `cabal freeze` before this
milestone and read the resolved version from `cabal.project.freeze`.

The full export list (from M1) is unchanged; the new functions are already
listed.

Run `nix fmt && cabal build shibuya-core`. Both must succeed.

Acceptance for M2: the module exports both `exponentialBackoff` and
`retryWithBackoff`; the test command `cabal repl shibuya-core` evaluates

    runEff (exponentialBackoff defaultBackoffPolicy (Attempt 2))

to a `RetryDelay` whose seconds are in `[0, 4]`. (The upper bound is `base *
factor^2 = 4` seconds; the lower is `0` because of FullJitter.)


### Milestone 3: Tests and CHANGELOG

Create `shibuya-core/test/Shibuya/Core/RetrySpec.hs`:

    {-# LANGUAGE OverloadedStrings #-}

    module Shibuya.Core.RetrySpec (spec) where

    import Data.Maybe (fromMaybe)
    import Data.Time (NominalDiffTime, nominalDiffTimeToSeconds)
    import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
    import Shibuya.Core.Retry
    import Shibuya.Core.Types (Attempt (..))
    import Test.Hspec
    import Test.QuickCheck

    secondsOf :: RetryDelay -> Double
    secondsOf (RetryDelay d) = realToFrac (nominalDiffTimeToSeconds d)

    spec :: Spec
    spec = do
      describe "exponentialBackoffPure" $ do
        describe "NoJitter" $ do
          let p = defaultBackoffPolicy {jitter = NoJitter}
          it "delay = base at attempt 0" $
            secondsOf (exponentialBackoffPure p (Attempt 0) 0) `shouldBe` 1.0
          it "delay doubles each attempt" $ do
            secondsOf (exponentialBackoffPure p (Attempt 1) 0) `shouldBe` 2.0
            secondsOf (exponentialBackoffPure p (Attempt 2) 0) `shouldBe` 4.0
            secondsOf (exponentialBackoffPure p (Attempt 3) 0) `shouldBe` 8.0
          it "delay clamps to maxDelay" $ do
            -- 2^20 = 1048576 ≫ 300 seconds
            secondsOf (exponentialBackoffPure p (Attempt 20) 0) `shouldBe` 300.0
          it "ignores the jitter sample" $ do
            secondsOf (exponentialBackoffPure p (Attempt 3) 0)
              `shouldBe` secondsOf (exponentialBackoffPure p (Attempt 3) 0.999)

        describe "FullJitter" $ do
          let p = defaultBackoffPolicy {jitter = FullJitter}
          it "delay at sample 0 is 0" $
            secondsOf (exponentialBackoffPure p (Attempt 5) 0) `shouldBe` 0.0
          it "delay at sample ~1 approaches baseExp" $
            secondsOf (exponentialBackoffPure p (Attempt 2) 0.999) `shouldSatisfy` (\x -> x > 3.99 && x < 4.0)
          it "delay never exceeds the clamped baseExp" $ property $ \(NonNegative n) (Positive s :: Positive Double) -> do
            let attemptN = Attempt (fromIntegral (n :: Int))
                sample = min 0.999 (s - fromIntegral (truncate s :: Int)) -- in [0,1)
                delay = secondsOf (exponentialBackoffPure p attemptN sample)
            delay `shouldSatisfy` (\d -> d >= 0 && d <= 300)

        describe "EqualJitter" $ do
          let p = defaultBackoffPolicy {jitter = EqualJitter}
          it "delay at sample 0 is half the baseExp" $
            secondsOf (exponentialBackoffPure p (Attempt 2) 0) `shouldBe` 2.0
          it "delay at sample ~1 approaches the full baseExp" $
            secondsOf (exponentialBackoffPure p (Attempt 2) 0.999) `shouldSatisfy` (\x -> x > 3.99 && x < 4.0)

        describe "Attempt 0" $ do
          it "with NoJitter equals base" $
            secondsOf (exponentialBackoffPure (defaultBackoffPolicy {jitter = NoJitter}) (Attempt 0) 0) `shouldBe` 1.0
          it "with FullJitter is in [0, base)" $ property $ \(s :: Double) -> do
            let sample = abs s - fromIntegral (truncate (abs s) :: Int)
                delay = secondsOf (exponentialBackoffPure (defaultBackoffPolicy {jitter = FullJitter}) (Attempt 0) sample)
            delay `shouldSatisfy` (\d -> d >= 0 && d <= 1)

      describe "retryWithBackoff" $ do
        it "produces AckRetry" $ do
          import Shibuya.Core.Types (Envelope (..), MessageId (..))
          let env =
                Envelope
                  { messageId = "x",
                    cursor = Nothing,
                    partition = Nothing,
                    enqueuedAt = Nothing,
                    traceContext = Nothing,
                    attempt = Just (Attempt 1),
                    payload = ()
                  }
          decision <- runEff (retryWithBackoff defaultBackoffPolicy env)
          case decision of
            AckRetry _ -> pure ()
            other -> expectationFailure $ "expected AckRetry, got " <> show other

(Note: the `import` line nested inside `it` is illegal Haskell — replace it
with a top-level `import` once the spec module is being written. The example
above is a quick illustration; clean it up when implementing.)

Wire the new spec into `shibuya-core/test/Main.hs`:

    -- Add this import alongside the others:
    import qualified Shibuya.Core.RetrySpec

    -- Add this in the main spec hierarchy alongside other Core specs:
    describe "Shibuya.Core.Retry" Shibuya.Core.RetrySpec.spec

Add the module to the test stanza's `other-modules` in
`shibuya-core/shibuya-core.cabal`:

    Shibuya.Core.RetrySpec

Update `shibuya-core/CHANGELOG.md` `Unreleased` section (created by EP-1) with:

    ### Additions

    - New module `Shibuya.Core.Retry` providing `BackoffPolicy`, `Jitter`,
      `defaultBackoffPolicy`, the pure evaluator `exponentialBackoffPure`,
      the effectful `exponentialBackoff`, and the handler convenience
      `retryWithBackoff`. See the module haddock and the new
      `RetrySpec` test for usage patterns.

Run from the repo root:

    nix fmt
    cabal build all
    cabal test shibuya-core-test

All must succeed. The `RetrySpec` group must appear in the test output.

Acceptance for M3: `cabal test shibuya-core-test --test-show-details=direct
2>&1 | grep -E "Shibuya.Core.Retry|exponentialBackoff"` produces lines
showing each `it` block running and passing.


## Concrete Steps

From the repo root `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`:

    cabal build shibuya-core
    cabal test shibuya-core-test --test-show-details=direct
    nix fmt

After all three milestones, full verification:

    cabal clean
    cabal build all
    cabal test shibuya-core-test --test-show-details=direct

Expected tail:

    Shibuya.Core.Retry
      exponentialBackoffPure
        NoJitter
          delay = base at attempt 0
          delay doubles each attempt
          ...
      retryWithBackoff
        produces AckRetry

    Finished in 0.0X seconds
    NN examples, 0 failures


## Validation and Acceptance

A reader can verify by:

1. Building and testing per the Concrete Steps. All RetrySpec assertions pass.
2. Opening `cabal repl shibuya-core` and running:

       :set -XOverloadedStrings -XOverloadedRecordDot
       import Shibuya.Core.Retry
       import Shibuya.Core.Types (Attempt(..))
       import Effectful (runEff)
       runEff (exponentialBackoff defaultBackoffPolicy (Attempt 4))

   Output is a `RetryDelay` whose seconds, repeated 100 times, span the range
   `[0, 16)` (because `base * factor^4 = 16`).

3. Confirming `cabal haddock shibuya-core` renders the new module's docs.


## Idempotence and Recovery

Each milestone's edits are additive (new file, new export, new test). If a
milestone is interrupted, the partial state can be reconciled with `cabal
build`, which will report the missing pieces precisely. `git restore` rolls
back any subset.

The `random` build-depends bound (M2) is the only place this plan can
introduce a solver conflict. If `cabal build` fails at M2 with a "could not
resolve random" error, narrow the bound to whatever `ghc-pkg list random`
reports as the bundled version's series.


## Interfaces and Dependencies

New build-depends on `shibuya-core`:

- `random ^>=1.2`

At the end of this plan, `Shibuya.Core.Retry` exports:

    data BackoffPolicy = BackoffPolicy
      { base     :: !NominalDiffTime
      , factor   :: !Double
      , maxDelay :: !NominalDiffTime
      , jitter   :: !Jitter
      }

    data Jitter = NoJitter | FullJitter | EqualJitter

    defaultBackoffPolicy   :: BackoffPolicy

    exponentialBackoffPure :: BackoffPolicy -> Attempt -> Double -> RetryDelay
    exponentialBackoff     :: (IOE :> es) => BackoffPolicy -> Attempt -> Eff es RetryDelay
    retryWithBackoff       :: (IOE :> es) => BackoffPolicy -> Envelope msg -> Eff es AckDecision

These are *not* re-exported from `Shibuya.Core` — application authors who
want backoff explicitly import `Shibuya.Core.Retry`. The reasoning: most
handlers don't need backoff, and keeping `Shibuya.Core` lean preserves its
"essentials only" character. The follow-on plan
`docs/plans/8-demonstrate-backoff-end-to-end.md` may revisit this if the
demo surface a strong ergonomic argument.
