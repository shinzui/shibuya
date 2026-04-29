# Demonstrate exponential backoff end-to-end with a runnable example

MasterPlan: docs/masterplans/1-exponential-backoff-for-retries.md
Intention: intention_01kqbspdwse4tv03dbkbyt1cmg

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, a curious reader can clone the Shibuya project, run a single
example binary against a local PostgreSQL with pgmq installed, and watch a handler
fail the first three deliveries of a message and succeed on the fourth — with the
retry intervals visibly growing exponentially. This is the integration moment for
the whole "Exponential Backoff for Retries" initiative: it proves the Envelope field
(EP-1), the policy module (EP-2), and the pgmq integration (EP-3) work together at
the user-visible level.

Without this plan, the API exists but no example proves the API actually feels right
end-to-end. Adding a worked example surfaces ergonomic problems that would otherwise
ship to first users.

A reader can verify the change by:

1. From the pgmq-adapter repo root, starting Postgres with pgmq installed (per the
   adapter repo's README), then running `cabal run shibuya-pgmq-example -- backoff`
   (or whatever subcommand this plan adds; see Plan of Work).
2. Observing the program's stdout: a single message is enqueued, fails three times
   (the handler logs each failure with `attempt = N` and the delay until the next
   retry), and succeeds on attempt 3. The intervals between failure logs grow:
   roughly 0–1 s, 0–2 s, 0–4 s under `defaultBackoffPolicy` with full jitter.
3. Re-running the example with `--policy nojitter` to see deterministic intervals
   (1 s, 2 s, 4 s) and confirm the math.
4. Reading the new `README` snippet at the top of the main `shibuya` repo's README
   and reproducing the steps in under five minutes.

This plan hard-depends on `docs/plans/6-add-backoff-policy-module.md` (uses
`retryWithBackoff`) and `docs/plans/7-populate-attempt-from-pgmq-readcount.md` (the
adapter must populate `attempt`).


## Progress

- [x] Milestone 1 — Added `backoffDemoHandler` and `backoffDemoAdapterConfig`
      to
      `shibuya-pgmq-adapter/shibuya-pgmq-example/app/Consumer.hs`. Wired a
      `backoff-demo` subcommand (with optional `nojitter` /
      `equaljitter` flag) via a new `runBackoffDemoMain` /
      `runBackoffDemoConsumer` pair. Added `backoff_demo` queue to
      `Example.Database` so `createQueues` provisions it. Added
      `containers ^>=0.7` to the `shibuya-pgmq-consumer` executable's
      build-depends. *(2026-04-29)*
- [ ] Milestone 2 — Add a tiny "send one message, then exit" mode to the
      `Simulator.hs` companion in the same example, so an operator can run
      `cabal run shibuya-pgmq-example-simulator -- one-shot` to enqueue
      exactly one message and then run the consumer in `backoff-demo`
      mode against it. Capture a sample transcript with timestamps; record
      it in this plan's `Outcomes & Retrospective` section.
- [ ] Milestone 3 — Update the top-level `README.md` in the main `shibuya`
      repository with a "Exponential Backoff" subsection containing the
      worked snippet. Cross-reference the demo from
      `shibuya-core/CHANGELOG.md` and `shibuya-pgmq-adapter/CHANGELOG.md`
      `Unreleased` sections.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Put the demo in the existing `shibuya-pgmq-example` package
  rather than creating a new package.
  Rationale: The example package already wires Postgres setup, pgmq
  initialization, and supervised processor configuration. Adding another
  handler is an order of magnitude smaller than spinning up a new
  package. The demo is itself an exemplar of how an application would
  use `retryWithBackoff`, which is exactly what `shibuya-pgmq-example`
  is for.
  Date: 2026-04-28.

- Decision: Track per-message failure counts in an `IORef` map keyed by
  `MessageId`, rather than embedding a counter in the message payload.
  Rationale: The point of the demo is to exercise the framework's own
  delivery counter (`Envelope.attempt`). Reading from the payload would
  bypass that. The `IORef` is local to the handler and used purely to
  decide whether to fail or succeed for a given message; the *delay
  decision* is driven by `envelope.attempt`.
  Date: 2026-04-28.

- Decision: Keep the demo handler synchronous (uses `liftIO putStrLn` for
  observability) rather than wiring it into the metrics web UI.
  Rationale: Watching exponential spacing is most obvious in stdout
  timestamps. The metrics web UI would be a nice extension but is out of
  scope for the proof-of-feature milestone.
  Date: 2026-04-28.


## Outcomes & Retrospective

(To be filled during and after implementation. Include the captured
transcript from M2 here.)


## Context and Orientation

This plan touches the *sibling* PGMQ adapter repository, with one small
edit (the README) in the main `shibuya` repository. The relevant paths:

- Main repo: `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`. The
  `README.md` here is the user-facing entry point.
- PGMQ adapter repo:
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`.
  The example package is at `shibuya-pgmq-example/` inside this repo.

The example package layout, observed during research:

- `shibuya-pgmq-adapter/shibuya-pgmq-example/app/Consumer.hs` — the
  consumer-side `main`. Wires three handlers (`ordersHandler`,
  `paymentsHandler`, `notificationsHandler`) to three queues and starts
  supervised processors. Uses `runApp` from `Shibuya.App`.
- `shibuya-pgmq-adapter/shibuya-pgmq-example/app/Simulator.hs` — the
  producer-side `main`. Sends synthetic messages on a loop.

The handlers in `Consumer.hs` use this pattern:

    ordersHandler ::
      ... =>
      Handler es Value
    ordersHandler (Ingested {envelope = Envelope {payload, messageId = MessageId msgIdText}}) = do
      ...
      pure AckOk

After EP-1, `Envelope` includes the `attempt` field; after EP-2,
`Shibuya.Core.Retry.retryWithBackoff` is available; after EP-3, pgmq
populates `attempt` from `readCount`. This plan composes those into a
worked example.

A "subcommand" mode is the existing convention in the example: see
how `Consumer.hs` and `Simulator.hs` parse their arguments. If the
existing pattern is just "run a fixed configuration," adding a `case
args of` switch is acceptable; keep the change minimal.

The pgmq adapter test suite uses `tmp-postgres` for hermetic Postgres
setup. The example, in contrast, expects a real Postgres running on the
local machine with pgmq installed. The README in the adapter repo
documents that setup; this plan should not duplicate it but should
reference it.


## Plan of Work


### Milestone 1: Add the backoff demo handler

Open
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-example/app/Consumer.hs`.

Add the new handler. The shape:

    -- | Demonstrates exponential backoff. Fails the first three deliveries
    -- of every message, then succeeds. Logs each delivery with its attempt
    -- count.
    backoffDemoHandler ::
      (IOE :> es, ...) =>
      IORef (Map MessageId Int) ->
      BackoffPolicy ->
      Handler es Value
    backoffDemoHandler failuresRef policy ingested = do
      let env = ingested.envelope
          msgId = env.messageId
          attempt = fromMaybe (Attempt 0) env.attempt
      now <- liftIO getCurrentTime
      liftIO $ putStrLn $
        "[" <> show now <> "] msg=" <> show msgId
        <> " attempt=" <> show (unAttempt attempt)
      currentFails <- liftIO $ atomicModifyIORef' failuresRef $ \m ->
        let n = Map.findWithDefault 0 msgId m
         in (Map.insert msgId (n + 1) m, n)
      if currentFails < 3
        then do
          decision <- retryWithBackoff policy env
          case decision of
            AckRetry (RetryDelay d) ->
              liftIO $ putStrLn $ "  -> retry in " <> show d
            _ -> pure ()
          pure decision
        else do
          liftIO $ putStrLn "  -> success"
          pure AckOk

Required imports (incremental over what's already in the module):

    import Data.IORef (IORef, atomicModifyIORef', newIORef)
    import Data.Map.Strict (Map)
    import Data.Map.Strict qualified as Map
    import Data.Maybe (fromMaybe)
    import Data.Time (getCurrentTime)
    import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
    import Shibuya.Core.Retry (BackoffPolicy, defaultBackoffPolicy, retryWithBackoff)
    import Shibuya.Core.Types (Attempt (..), Envelope (..))

Wire the handler into the existing `main` dispatcher. If `Consumer.hs`
parses arguments via `getArgs`, add a branch:

    case args of
      ["backoff-demo"] -> runBackoffDemo
      ["backoff-demo", "nojitter"] -> runBackoffDemo' (defaultBackoffPolicy {jitter = NoJitter})
      _ -> runDefault   -- existing behavior

Where `runBackoffDemo`:

1. Parses a hardcoded queue name (e.g., `backoff_demo`).
2. Acquires a Hasql `Pool`.
3. Runs `Pgmq.createQueue` if the queue doesn't already exist (consult
   the pgmq-effectful API at
   `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful`
   for the function name).
4. Builds an adapter via `pgmqAdapter` with `defaultConfig
   { maxRetries = 5 }` (allow 5 deliveries since the handler fails the
   first 3).
5. Builds the failures IORef.
6. Calls `runApp` with one processor wired to `backoffDemoHandler`.
7. Waits for completion or `Ctrl-C`.

Run, from the pgmq-adapter repo root:

    cabal build shibuya-pgmq-example

Acceptance for M1: build succeeds; `cabal run shibuya-pgmq-example -- --help`
or equivalent shows the new subcommand listed; the handler imports cleanly.


### Milestone 2: One-shot simulator and capture a transcript

Open
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-example/app/Simulator.hs`.

Add a `one-shot` mode. The shape:

    case args of
      ["one-shot", queueName] ->
        runOneShot (parseQueueNameOrDie queueName)
      ["one-shot"] ->
        runOneShot defaultBackoffDemoQueue
      _ -> runDefault

`runOneShot` enqueues a single JSON message and exits.

To capture the transcript, run the demo locally:

1. Start a local Postgres with pgmq installed (per the adapter repo's
   README).
2. From `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`:

       cabal build all
       cabal run shibuya-pgmq-example-simulator -- one-shot backoff_demo

3. In a second terminal, also from the adapter repo root:

       cabal run shibuya-pgmq-example -- backoff-demo nojitter

4. The consumer prints something like:

       [2026-04-28 14:00:00 UTC] msg=42 attempt=0
         -> retry in 1s
       [2026-04-28 14:00:01 UTC] msg=42 attempt=1
         -> retry in 2s
       [2026-04-28 14:00:03 UTC] msg=42 attempt=2
         -> retry in 4s
       [2026-04-28 14:00:07 UTC] msg=42 attempt=3
         -> success

   The intervals are 1, 2, 4 — exponential. With `defaultBackoffPolicy`
   (full jitter), the intervals are random within `[0, 1)`, `[0, 2)`,
   `[0, 4)`, but the upper bounds still demonstrate the exponential
   shape.

Paste the captured transcript into this plan's `Outcomes &
Retrospective` section. Then commit.

Acceptance for M2: a real run produces a transcript matching the
described shape; the transcript is recorded in this plan; the example
binary is invocable as documented.


### Milestone 3: README + CHANGELOG cross-references

Open the main repository's README at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/README.md`. Add a
new top-level section (or extend an existing "Examples" section) titled
"Exponential Backoff" with the worked snippet:

    ## Exponential Backoff

    Shibuya 0.4 ships a built-in exponential-backoff helper. Handlers
    that want exponentially-growing, jittered retry intervals can write:

        import Shibuya.Core.Retry (defaultBackoffPolicy, retryWithBackoff)

        myHandler ingested = do
          result <- tryProcess ingested.envelope.payload
          case result of
            Right () -> pure AckOk
            Left _  -> retryWithBackoff defaultBackoffPolicy ingested.envelope

    With the PGMQ adapter, the framework populates
    `ingested.envelope.attempt` from pgmq's read counter, so the
    delay grows each time the same message returns. See the runnable
    demo at `shibuya-pgmq-adapter/shibuya-pgmq-example/` (subcommand
    `backoff-demo`).

Open `shibuya-core/CHANGELOG.md` and `shibuya-pgmq-adapter/CHANGELOG.md`
(in the adapter repo). In each `Unreleased` section, add a line:

    - End-to-end demo of the new API lives at
      `shibuya-pgmq-adapter/shibuya-pgmq-example/` under the
      `backoff-demo` subcommand. See
      `docs/plans/8-demonstrate-backoff-end-to-end.md` (in the main
      repo) for setup instructions.

Run `nix fmt` in both repos.

Acceptance for M3: README renders the new section correctly when
viewed in a Markdown previewer; both CHANGELOGs link to the demo.


## Concrete Steps

From the main repo
(`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`):

    nix fmt

From the pgmq-adapter repo
(`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`):

    cabal build all
    cabal test shibuya-pgmq-adapter-test
    nix fmt

For the live demo (M2), assuming Postgres+pgmq is running locally:

    # Terminal 1 — producer
    cabal run shibuya-pgmq-example-simulator -- one-shot backoff_demo

    # Terminal 2 — consumer
    cabal run shibuya-pgmq-example -- backoff-demo nojitter

Expected combined output (consumer's stdout):

    [...UTC] msg=N attempt=0
      -> retry in 1s
    [...UTC] msg=N attempt=1
      -> retry in 2s
    [...UTC] msg=N attempt=2
      -> retry in 4s
    [...UTC] msg=N attempt=3
      -> success

The wallclock gap between each `attempt=K` log and the next `attempt=K+1`
log should approximately match the printed `retry in Ts` value.


## Validation and Acceptance

The plan is "done" when:

1. The new subcommand is wired and exercised in a real-Postgres run.
2. The captured transcript demonstrates wallclock gaps that match the
   logged `retry in Ts` values within ±0.5 seconds (allowing for
   pgmq polling jitter and processor startup).
3. The README snippet copy-pastes into a fresh handler and typechecks.
4. The main repo's CHANGELOG points to the demo location.

If the wallclock gaps systematically exceed the logged delays, suspect
the polling interval in `defaultPollingConfig` (1 second). The demo
either documents this caveat or sets a tighter `pollInterval` in the
demo config.


## Idempotence and Recovery

The demo subcommand uses a fixed queue name. Re-running the simulator
enqueues additional messages; re-running the consumer reads them in
order. Dropping the queue between runs (`pgmq.drop_queue('backoff_demo')`)
is the simplest reset. The README snippet should mention this so the
reader can recover from a confused state.

The README and CHANGELOG edits are pure additions; `git restore`
trivially undoes them.


## Interfaces and Dependencies

This plan adds no new packages. It uses:

- `Shibuya.Core.Retry` (from EP-2): `BackoffPolicy`, `Jitter`,
  `defaultBackoffPolicy`, `retryWithBackoff`.
- `Shibuya.Core.Types` (from EP-1): `Envelope`, `Attempt`.
- `Shibuya.Adapter.Pgmq` (from EP-3): the populated `attempt` field.

If the adapter's example already lacks `containers` or `time` in its
build-depends (unlikely), add them. Most of the imports above are
already in the example.

After this plan, the project ships a runnable, observable demonstration
of the exponential-backoff API end-to-end. The MasterPlan's vision is
satisfied.
