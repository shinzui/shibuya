# Populate Envelope.attempt from pgmq readCount + defensive Int32 clamp

MasterPlan: docs/masterplans/1-exponential-backoff-for-retries.md
Intention: intention_01kqbspdwse4tv03dbkbyt1cmg

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, every message ingested through the PGMQ adapter
(`shibuya-pgmq-adapter`) carries the correct delivery counter on its envelope.
A Shibuya handler reading `ingested.envelope.attempt` sees `Just (Attempt 0)`
on the first delivery, `Just (Attempt 1)` on the first retry, and so on. This
unblocks the whole exponential-backoff API for PGMQ users.

In addition, this change adds a defensive clamp to the visibility-timeout
extension that the adapter performs on `AckRetry`. PGMQ's
`changeVisibilityTimeout` takes seconds as `Int32`, so a `RetryDelay` with a
very large `NominalDiffTime` could theoretically overflow during conversion.
The clamp makes the conversion safe: a retry of "100 years" silently caps at
`maxBound :: Int32` seconds (~68 years) instead of crashing the adapter or
silently wrapping to a tiny negative value.

Without this plan, a handler that has the field on `Envelope` (added by
`docs/plans/5-add-attempt-to-envelope.md`) would always see `Nothing` from
PGMQ — defeating the purpose of the field. After this plan, the field is
populated and consumable.

A reader can verify the change by:

1. Building `cabal build shibuya-pgmq-adapter` from
   `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` and
   observing it succeeds.
2. Running `cabal test shibuya-pgmq-adapter-test --test-show-details=direct`
   and seeing two new test groups pass: one in `ConvertSpec` covering the
   `attempt` field for several `readCount` values, and one in
   `IntegrationSpec` (or a new spec) covering the `Int32` clamp.
3. Manually publishing a message and re-reading it through the adapter; the
   second delivery's envelope shows `attempt = Just (Attempt 1)`.

This plan hard-depends on `docs/plans/5-add-attempt-to-envelope.md` because it
writes to a field that does not exist yet. It soft-depends on
`docs/plans/6-add-backoff-policy-module.md` only at the documentation level —
the haddock for `Shibuya.Adapter.Pgmq` mentions `retryWithBackoff` as the
recommended handler-side helper.


## Progress

- [x] Milestone 1 — Update `pgmqMessageToEnvelope` in
      `shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`
      to populate `attempt` from `msg.readCount`. Add unit tests in
      `shibuya-pgmq-adapter/shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConvertSpec.hs`
      covering `readCount = 1` (first delivery, Attempt 0), `readCount = 2`
      (first retry, Attempt 1), `readCount = 5` (fourth retry, Attempt 4),
      and the boundary `readCount = 0` (which pgmq doesn't actually emit, but
      the conversion must not panic — clamp to `Attempt 0`). *(2026-04-29)*
- [x] Milestone 2 — Replace the unsafe `nominalToSeconds` use in
      `shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`
      with a clamping variant that saturates at `maxBound :: Int32` (kept
      the same name and signature so call sites need no change). Added
      four new test cases under `nominalToSeconds clamping` covering
      30 seconds, subsecond rounding, the 100-year clamp, and the
      negative-direction clamp. *(2026-04-29)*
- [x] Milestone 3 — Updated the "Retry Handling" haddock section in
      `shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`
      with a snippet pointing at `Shibuya.Core.Retry.retryWithBackoff` and
      mentioning the `Int32` clamp. Added an `Unreleased` section to
      `shibuya-pgmq-adapter/shibuya-pgmq-adapter/CHANGELOG.md` covering
      the field, the clamp, and the new `shibuya-core ^>=0.4.0.0`
      requirement. The cabal lower-bound bump itself was made earlier
      (with M1's commit) so the build could resolve against the local
      `shibuya-core 0.4.0.0`. *(2026-04-29)*


## Surprises & Discoveries

- The plan assumed the adapter could simply bump its `shibuya-core` lower
  bound to `^>=0.4.0.0` and develop against a local checkout, but the main
  repo's `shibuya-core/shibuya-core.cabal` was still at `version: 0.3.0.0`
  even though EP-1's CHANGELOG declared the next release as `0.4.0.0`.
  Cabal's resolver enforces the version literally, so without bumping the
  main repo too, no version of `shibuya-core` could satisfy `^>=0.4.0.0`.
  Resolved by:
  1. Bumping `shibuya-core` to `0.4.0.0` in
     `shibuya/shibuya-core/shibuya-core.cabal`.
  2. Bumping the corresponding lower bound in
     `shibuya/shibuya-metrics/shibuya-metrics.cabal` from `^>=0.3.0.0` to
     `^>=0.4.0.0` so the in-repo build still resolves cleanly.
  3. Adding a (gitignored) `cabal.project.local` to the adapter repo with
     `packages: ../shibuya/shibuya-core ../shibuya/shibuya-metrics` so the
     adapter builds against the local checkouts during development. The
     `shibuya-metrics` override is needed because `shibuya-pgmq-example`
     transitively pulls it and the published `shibuya-metrics-0.3.0.0`
     still pins `shibuya-core ^>=0.3.0.0`.
  Date: 2026-04-29.


## Decision Log

- Decision: Compute `attempt` as `Just (Attempt (fromIntegral (max 0
  (readCount - 1))))` rather than `Just (Attempt (fromIntegral readCount))`.
  Rationale: pgmq increments `readCount` *on read*, so the first delivery
  has `readCount = 1`. A handler that wants "this is retry N" semantics
  (where `N = 0` means "first try") needs the read count decremented by one.
  This matches the framework-wide convention chosen for `Attempt`. The
  `max 0` guards against `readCount = 0` which pgmq does not emit but which
  cannot be ruled out at the type level.
  Date: 2026-04-28.

- Decision: Clamp at the `Int32` boundary inside the adapter, not inside the
  `BackoffPolicy` evaluator.
  Rationale: Different queue backends have different visibility-timeout
  ceilings. PGMQ uses `Int32` seconds; SQS allows up to 12 hours; Kafka
  doesn't have visibility timeouts at all. Pushing the clamp into the
  policy module would force the policy to know about every adapter's
  limit. The adapter is the natural place. The clamp also gives users a
  coherent failure mode for misconfigured `maxDelay` values: a
  100-year retry simply caps at the adapter's safe maximum rather than
  panicking or wrapping silently.
  Date: 2026-04-28.

- Decision: Do not change the existing `maxRetries` auto-DLQ behavior at
  `Internal.hs:260`.
  Rationale: That code is the safety net that prevents infinite retries
  even with an unbounded `BackoffPolicy`. The original
  `EXPONENTIAL_BACKOFF_DESIGN.md` correctly notes this lets the policy
  module assume infinite attempts without risk. Changing it now would
  conflate two concerns and risk introducing a regression unrelated to
  this plan.
  Date: 2026-04-28.


## Outcomes & Retrospective

Completed on 2026-04-29. The PGMQ adapter now populates
`Envelope.attempt` from pgmq's `readCount` (0-indexed), and the
visibility-timeout extension is defensively clamped to the `Int32`
range so misconfigured `BackoffPolicy.maxDelay` values cannot cause
undefined behavior. The adapter's `Shibuya.Adapter.Pgmq` haddock now
points handler authors at `Shibuya.Core.Retry.retryWithBackoff`.

Achieved:

- 99 unit-test assertions pass (4 new for the `attempt` field and 4
  new for `nominalToSeconds` clamping).
- `shibuya-core ^>=0.4.0.0` lower bound is in place across the adapter
  library and test suite.

Discovered en route (recorded in Surprises): the main repo's
`shibuya-core/shibuya-core.cabal` was still at `version: 0.3.0.0`
even though EP-1 had already declared the next release as `0.4.0.0`,
so the version bump and a sibling lower-bound bump in
`shibuya-metrics` had to happen alongside this plan. A gitignored
`cabal.project.local` was added in the adapter repo to point at the
sibling shibuya-core/shibuya-metrics checkouts; once `shibuya-core
0.4.0.0` is published this local override can be deleted.

Not exercised by this plan: the live-PGMQ integration tests
(`IntegrationSpec`, `ChaosSpec`) — they require a running Postgres
with the pgmq extension. They will be exercised by EP-4's end-to-end
demo run.


## Context and Orientation

This plan touches a *sibling* repository, not the main `shibuya` repository.
The relevant paths are:

- Main `shibuya` repo: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.
  Hosts `shibuya-core`, which defines `Envelope`, `Attempt`, and `RetryDelay`.
  The work for this plan does *not* edit anything in this repo, but the file
  paths it reads (e.g., `shibuya-core/src/Shibuya/Core/Types.hs`) live here.
- PGMQ adapter repo: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.
  All edits in this plan happen inside this repo.

The PGMQ adapter exposes a `Shibuya.Adapter.Pgmq` module
(`shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`). Its
internal helpers live in:

- `Shibuya/Adapter/Pgmq/Convert.hs` — converts pgmq's `Message` type into
  Shibuya's `Envelope`. The function `pgmqMessageToEnvelope` is the
  single point of envelope construction.
- `Shibuya/Adapter/Pgmq/Internal.hs` — the streaming source, ack handling,
  and lease helpers. The `mkAckHandle` function turns an `AckDecision` into
  a pgmq operation; on `AckRetry`, it converts the `RetryDelay` to seconds
  via `nominalToSeconds` and calls `changeVisibilityTimeout`.
- `Shibuya/Adapter/Pgmq/Config.hs` — the adapter's config record. Not
  touched by this plan.

The pgmq library's `Message` type (defined in
`/Users/shinzui/Keikaku/hub/postgresql/pgmq-project/pgmq-rs` for the SQL
extension and `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`
for the Haskell client) carries a `readCount :: Int64` field that the database
increments each time a worker reads the message. So:

- First read: `readCount = 1`
- Second read (after a retry): `readCount = 2`
- ...

The existing adapter already uses this: `mkIngested` in `Internal.hs` tests
`if msg.readCount > config.maxRetries` and auto-DLQs in that case.

`changeVisibilityTimeout` takes a `VisibilityTimeoutQuery` whose
`visibilityTimeoutOffset :: Int32` is in seconds. The conversion lives in
`Internal.hs`:

    nominalToSeconds :: NominalDiffTime -> Int32
    nominalToSeconds = ceiling . nominalDiffTimeToSeconds

`ceiling` on a `NominalDiffTime` larger than `maxBound :: Int32` (~ 68 years)
silently wraps in some implementations and panics with `arithmetic
overflow` in others, depending on the GHC RTS. We replace it with a clamping
variant.

The package's tests live under `shibuya-pgmq-adapter/test/`. Unit tests run
without a database (in `ConvertSpec`); integration tests use `tmp-postgres`
to spin up a real PostgreSQL with the pgmq extension installed. See
`shibuya-pgmq-adapter/shibuya-pgmq-adapter/test/TmpPostgres.hs`.

Testing requires:

- Nix devShell for `tmp-postgres` and the pgmq extension; or
- A locally running Postgres with pgmq installed and the env vars from the
  main repo's `CLAUDE.md` (`PGHOST=$PWD/db`, etc.).

Unit-only tests (`ConvertSpec`) do not need Postgres and run with `cabal
test shibuya-pgmq-adapter-test --test-options='--match Convert'`.


## Plan of Work


### Milestone 1: Populate `attempt` from `readCount`

Open `shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`.
The current `pgmqMessageToEnvelope` is:

    pgmqMessageToEnvelope :: Pgmq.Message -> Envelope Value
    pgmqMessageToEnvelope msg =
      Envelope
        { messageId = messageIdToShibuya msg.messageId,
          cursor = Just (pgmqMessageIdToCursor msg.messageId),
          partition = extractPartition msg.headers,
          enqueuedAt = Just msg.enqueuedAt,
          traceContext = extractTraceHeaders msg.headers,
          payload = Pgmq.unMessageBody msg.body
        }

Add the `attempt` field. After this plan, `Envelope` (defined in the main
`shibuya` repo at `shibuya-core/src/Shibuya/Core/Types.hs`) has the field
between `traceContext` and `payload`. The new shape:

    pgmqMessageToEnvelope :: Pgmq.Message -> Envelope Value
    pgmqMessageToEnvelope msg =
      Envelope
        { messageId = messageIdToShibuya msg.messageId,
          cursor = Just (pgmqMessageIdToCursor msg.messageId),
          partition = extractPartition msg.headers,
          enqueuedAt = Just msg.enqueuedAt,
          traceContext = extractTraceHeaders msg.headers,
          attempt = Just (readCountToAttempt msg.readCount),
          payload = Pgmq.unMessageBody msg.body
        }

    -- | Convert pgmq's 'readCount' (1-based, incremented on read) to a
    -- Shibuya 'Attempt' (0-based delivery counter).
    --
    -- pgmq increments 'readCount' before exposing the message, so on the
    -- first delivery 'readCount = 1' which corresponds to 'Attempt 0'.
    -- The 'max 0' clamp guards the unexpected 'readCount = 0' case.
    readCountToAttempt :: Int64 -> Attempt
    readCountToAttempt rc = Attempt (fromIntegral (max 0 (rc - 1)))

Add the imports:

    import Data.Int (Int64)
    import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), MessageId (..), TraceHeaders)

(`Int64` and `Attempt` were not previously needed; `Int64` may already be
imported elsewhere in the module — check first.)

Open `shibuya-pgmq-adapter/shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ConvertSpec.hs`
and add a new describe block. The existing test pattern destructures the
envelope; the new tests extract `.attempt`:

    describe "pgmqMessageToEnvelope (attempt)" $ do
      it "first delivery (readCount=1) -> Attempt 0" $ do
        let msg = mkPgmqMessage 1
            env = pgmqMessageToEnvelope msg
        env.attempt `shouldBe` Just (Attempt 0)

      it "first retry (readCount=2) -> Attempt 1" $ do
        let msg = mkPgmqMessage 2
            env = pgmqMessageToEnvelope msg
        env.attempt `shouldBe` Just (Attempt 1)

      it "fifth read (readCount=5) -> Attempt 4" $ do
        let msg = mkPgmqMessage 5
            env = pgmqMessageToEnvelope msg
        env.attempt `shouldBe` Just (Attempt 4)

      it "boundary readCount=0 clamps to Attempt 0" $ do
        let msg = mkPgmqMessage 0
            env = pgmqMessageToEnvelope msg
        env.attempt `shouldBe` Just (Attempt 0)

The helper `mkPgmqMessage` already exists or can be added; it should
produce a `Pgmq.Message` with the supplied `readCount` and arbitrary other
fields. Look for the existing test patterns in the file and reuse the same
helpers.

Acceptance for M1: from the pgmq-adapter repo root, `cabal test
shibuya-pgmq-adapter-test --test-show-details=direct --test-options='--match
\"pgmqMessageToEnvelope (attempt)\"'` runs all four assertions and they
pass.


### Milestone 2: Defensive `Int32` clamp on visibility-timeout extension

Open `shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`.
The current helper at line 94:

    nominalToSeconds :: NominalDiffTime -> Int32
    nominalToSeconds = ceiling . nominalDiffTimeToSeconds

Replace with a clamping variant:

    -- | Convert 'NominalDiffTime' to seconds as 'Int32', saturating at the
    -- 'Int32' bounds.
    --
    -- Used when extending pgmq visibility timeouts ('AckRetry', 'AckHalt',
    -- and lease extension). pgmq's @changeVisibilityTimeout@ accepts
    -- 'Int32' seconds; values larger than 'maxBound' (~68 years) silently
    -- wrap in @ceiling . nominalDiffTimeToSeconds@. This helper instead
    -- saturates, so a misconfigured 'BackoffPolicy.maxDelay' produces a
    -- merely-very-long retry rather than a corrupt or panic-inducing one.
    nominalToSeconds :: NominalDiffTime -> Int32
    nominalToSeconds dt =
      let seconds :: Double
          seconds = realToFrac (nominalDiffTimeToSeconds dt)
          maxSec :: Double
          maxSec = fromIntegral (maxBound :: Int32)
          minSec :: Double
          minSec = fromIntegral (minBound :: Int32)
          clamped = max minSec (min maxSec seconds)
       in ceiling clamped

The function name and signature stay the same, so all existing call sites
continue to work without edits. The implementation is now safe for any
finite `NominalDiffTime`.

Add a test in
`shibuya-pgmq-adapter/shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/PropertySpec.hs`
or a new `InternalSpec.hs`:

    describe "nominalToSeconds clamping" $ do
      it "exact 30 seconds" $ do
        nominalToSeconds 30 `shouldBe` 30

      it "rounds up subsecond" $ do
        nominalToSeconds 0.1 `shouldBe` 1

      it "clamps a 100-year delay to maxBound :: Int32" $ do
        let hundredYears = 100 * 365 * 24 * 60 * 60 :: NominalDiffTime
        nominalToSeconds hundredYears `shouldBe` (maxBound :: Int32)

      it "clamps a negative delay to minBound :: Int32 (defensive only)" $ do
        nominalToSeconds (-1e20) `shouldBe` (minBound :: Int32)

If creating a new spec module, list it in the test stanza's `other-modules`
in `shibuya-pgmq-adapter/shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`,
and wire it into `shibuya-pgmq-adapter/shibuya-pgmq-adapter/test/Main.hs`.

`nominalToSeconds` is currently exported from `Internal.hs` (see the
existing module export list); it is exported from the Internal module so
this test can import it.

Acceptance for M2: from the pgmq-adapter repo root,
`cabal test shibuya-pgmq-adapter-test --test-show-details=direct
--test-options='--match \"nominalToSeconds clamping\"'` shows all four
assertions passing.


### Milestone 3: Documentation and CHANGELOG

Open `shibuya-pgmq-adapter/shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs`
and find the "Retry Handling" section in the module haddock (currently
around lines 40-44). Extend it:

    -- == Retry Handling
    --
    -- pgmq tracks retry attempts via the 'readCount' field. When a message's
    -- 'readCount' exceeds 'maxRetries' in the config, it is automatically
    -- dead-lettered before being passed to the handler.
    --
    -- The current attempt (zero-indexed) is exposed on the envelope as
    -- @envelope.attempt :: Maybe Attempt@. Handlers wanting exponential
    -- backoff can use 'Shibuya.Core.Retry.retryWithBackoff':
    --
    -- @
    -- import Shibuya.Core.Retry (defaultBackoffPolicy, retryWithBackoff)
    --
    -- handler ingested = do
    --   result <- tryProcess ingested.envelope.payload
    --   case result of
    --     Right () -> pure AckOk
    --     Left _  -> retryWithBackoff defaultBackoffPolicy ingested.envelope
    -- @
    --
    -- The adapter clamps any 'RetryDelay' to fit within pgmq's @Int32@
    -- second range (~68 years), so a long 'BackoffPolicy.maxDelay' is
    -- safe.

Open `shibuya-pgmq-adapter/shibuya-pgmq-adapter/CHANGELOG.md`. Add (or
extend) the `Unreleased` section:

    ## Unreleased

    ### Additions

    - Envelopes now carry the delivery 'attempt' counter (from pgmq's
      'readCount', zero-indexed), enabling exponential backoff via
      'Shibuya.Core.Retry'.

    ### Internal

    - 'nominalToSeconds' (in 'Shibuya.Adapter.Pgmq.Internal') now clamps to
      the 'Int32' range instead of silently wrapping. Misconfigured
      retry/lease durations cap at ~68 years rather than producing
      undefined behavior.

    ### Compatibility

    - Requires `shibuya-core ^>=0.4.0.0` for the `Attempt` type and the
      `attempt` field on `Envelope`.

Bump the cabal `build-depends` lower bound on `shibuya-core`. Open
`shibuya-pgmq-adapter/shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal` and
change:

    shibuya-core ^>=0.3.0.0,

to:

    shibuya-core ^>=0.4.0.0,

(The actual `0.4.0.0` cabal bump in the main repo happens at release time;
this lower bound expresses the intent and will fail loudly if someone
tries to build the adapter against the older shape.)

Run, from the pgmq-adapter repo root
(`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`):

    nix fmt
    cabal build all
    cabal test shibuya-pgmq-adapter-test

The build should fail at this milestone *unless* EP-1 has been applied to
the main repo (because the adapter now depends on
`shibuya-core ^>=0.4.0.0` which doesn't exist yet). This is intentional:
the dependency declaration documents the requirement. Once EP-1 lands and
`shibuya-core 0.4.0.0` is available (or wired via a local
`source-repository-package` stanza in `cabal.project` for development),
the build will pass.

Acceptance for M3: the haddock `Retry Handling` section renders cleanly via
`cabal haddock shibuya-pgmq-adapter`; the CHANGELOG mentions the field, the
clamp, and the version bump; the cabal build-depends lower bound is
`>=0.4.0.0`.


## Concrete Steps

From the pgmq-adapter repo root
(`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`):

    cabal build all
    cabal test shibuya-pgmq-adapter-test --test-show-details=direct
    nix fmt

Note that the build commands assume EP-1 has been applied to the main
`shibuya` repo and that the adapter's `cabal.project` either pulls
`shibuya-core` from a local path or a published 0.4.0.0. During
development before 0.4.0.0 is released, add a `source-repository-package`
stanza to the adapter repo's `cabal.project` pointing at the local main
repo:

    packages:
      shibuya-pgmq-adapter
      shibuya-pgmq-adapter-bench
      shibuya-pgmq-example

    -- Local development against unreleased shibuya-core
    source-repository-package
      type: git
      location: file:///Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
      tag: HEAD
      subdir: shibuya-core

(Or equivalent — the maintainer's typical setup likely already includes
this.)

Expected `cabal test` tail:

    pgmqMessageToEnvelope (attempt)
      first delivery (readCount=1) -> Attempt 0
      first retry (readCount=2) -> Attempt 1
      fifth read (readCount=5) -> Attempt 4
      boundary readCount=0 clamps to Attempt 0

    nominalToSeconds clamping
      exact 30 seconds
      rounds up subsecond
      clamps a 100-year delay to maxBound :: Int32
      clamps a negative delay to minBound :: Int32 (defensive only)

    Finished in N.NN seconds
    NN examples, 0 failures


## Validation and Acceptance

A reader can verify by:

1. Building and testing per the Concrete Steps. All new assertions pass.
2. Running the integration suite (requires Postgres + pgmq):

       cabal test shibuya-pgmq-adapter-test --test-show-details=direct \
         --test-options='--match Integration'

   The existing integration tests must continue to pass — adding the
   `attempt` field is additive at the protocol level.

3. Manually exercising the field. Start a Postgres with pgmq, send a
   message, read it once via the adapter, fail it (return `AckRetry`),
   wait for the visibility timeout, and read again. The second envelope's
   `attempt` field is `Just (Attempt 1)`.

4. Confirming the haddock renders the new "Retry Handling" prose:

       cabal haddock shibuya-pgmq-adapter --enable-documentation
       open dist-newstyle/build/.../doc/html/shibuya-pgmq-adapter/Shibuya-Adapter-Pgmq.html


## Idempotence and Recovery

Each milestone's edits are confined to one or two files plus tests, so a
failed milestone can be reverted with `git restore`. The cabal lower-bound
bump (M3) is the only step that can break the *build* of an in-development
adapter checkout; if the main repo's `shibuya-core` version is still
0.3.x.x, narrow the bound to `>=0.3.0.0` temporarily and revisit when the
main repo's version field actually moves to 0.4.0.0.

The clamp change in M2 strictly weakens the failure mode of
`nominalToSeconds` (less crash, more saturation). It cannot regress any
existing test that doesn't construct a value out of `Int32` range.


## Interfaces and Dependencies

This plan adds no new external dependencies. It bumps the
`shibuya-core` lower bound to `>=0.4.0.0`.

The `attempt` field on `Envelope` is the integration point shared with
the main `shibuya` repository (defined by EP-1, consumed by EP-2,
populated by this plan, demonstrated by EP-4).

After this plan, the public surface of `shibuya-pgmq-adapter` is unchanged.
The internal helper `nominalToSeconds` is now safer; the haddock
recommends `Shibuya.Core.Retry.retryWithBackoff` to handler authors.
