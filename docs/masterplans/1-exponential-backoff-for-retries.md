# Exponential Backoff for Retries

Intention: intention_01kqbspdwse4tv03dbkbyt1cmg

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/master-plan/MASTERPLAN.md`.


## Vision & Scope

After this initiative, a handler in any Shibuya application can ask the framework for an
exponentially-growing, jittered retry delay simply by reading the current delivery
attempt count off the message envelope and passing it to a small policy helper. The
helper produces an `AckRetry` decision; the adapter honors it. No handler ever has to
implement the math itself, and no adapter ever has to invent retry mechanics — both
sides meet at a single shared field on `Envelope` and a single shared policy type in
core.

Concretely, after the initiative is complete:

- `shibuya-core` exposes a new newtype `Attempt` (zero-indexed delivery counter), an
  optional `attempt :: !(Maybe Attempt)` field on `Envelope`, and a new module
  `Shibuya.Core.Retry` that defines `BackoffPolicy`, three jitter strategies
  (`NoJitter`, `FullJitter`, `EqualJitter`), and the helpers `exponentialBackoff`
  (effectful, samples randomness), `exponentialBackoffPure` (pure, takes a sample), and
  `retryWithBackoff` (one-liner that returns an `AckDecision`).
- `shibuya-pgmq-adapter` populates `attempt` from pgmq's `readCount` field and
  defensively clamps the visibility-timeout extension at `Int32` bounds.
- A runnable demonstration in `shibuya-pgmq-example` shows a handler that fails the
  first three deliveries, then succeeds, with the retry intervals growing exponentially
  in real time. The reader can launch the demo, watch the timestamps, and confirm the
  exponential spacing is observable end-to-end.

Out of scope:

- A framework-evaluated retry policy (where the framework consumes a `RetryDelay`
  variant carrying a policy and computes the delay on the handler's behalf). This was
  explicitly considered in `docs/plans/EXPONENTIAL_BACKOFF_DESIGN.md` and rejected
  because it pushes mechanics into `Shibuya.Core.Ack`, contradicting that module's
  separation of concerns, and forecloses per-error-type retry policies.
- Decorrelated jitter (per AWS's terminology). It requires the *previous* delay as
  input, which the handler doesn't naturally have unless it tracks per-key state. The
  three jitter strategies shipped here cover the AWS "exponential backoff with full
  jitter" recommendation and its common variants.
- Adapters other than pgmq. Kafka has no native delivery counter (offsets are not
  retries), so the same field stays `Nothing` for Kafka envelopes. A future Kafka
  consumer could synthesize `attempt` per partition+offset if desired, but that is
  separate work.


## Decomposition Strategy

The work decomposes naturally along three axes that map to the codebase's existing
boundaries:

1. **The shared envelope field** — a small but breaking change to the `Envelope`
   record in `shibuya-core`, plus updates to every in-tree construction site. This is
   the foundation; nothing else can land first.
2. **The retry policy module** — a new self-contained module `Shibuya.Core.Retry` in
   `shibuya-core`, including the helper that turns an `Attempt` into a `RetryDelay`
   and the convenience that wraps it in `AckRetry`. Pure plus effectful entry points,
   property-tested.
3. **The pgmq adapter integration** — populating `attempt` from `readCount`, plus the
   defensive `Int32` clamp on visibility-timeout extension. Lives entirely in the
   sibling repo `shibuya-pgmq-adapter`.
4. **End-to-end demonstration** — a worked example with a handler that fails the
   first N deliveries and uses `retryWithBackoff`, plus a CHANGELOG entry. This proves
   the user-visible behavior and gives the API a final-shape sanity check before any
   release.

Why this split and not others:

- *Why not fold (1) into (2)?* The envelope field has no observable behavior on its
  own, but separating it isolates the breaking change. Once (1) lands, (2) and (3) can
  proceed in parallel — that parallelism would be lost if the envelope field were part
  of the policy module.
- *Why not fold (2) and (3)?* They touch entirely different repositories and test
  suites. The policy module has only pure-and-property tests; the adapter integration
  has live-Postgres integration tests (via `tmp-postgres`). Forcing them into one plan
  would require a contributor to set up both environments to land any of it.
- *Why call out (4) separately?* The demonstration is the acceptance test for the
  whole initiative. Bundling it into (3) would let the API ship without an end-to-end
  proof; pulling it out as its own plan creates a deliberate "does this actually feel
  right?" review point.


## Exec-Plan Registry

| #     | Title                                                | Path                                                    | Hard Deps   | Soft Deps | Status      |
|-------|------------------------------------------------------|---------------------------------------------------------|-------------|-----------|-------------|
| EP-1  | Add Attempt newtype and attempt field on Envelope    | docs/plans/5-add-attempt-to-envelope.md                 | None        | None      | Complete    |
| EP-2  | Add Shibuya.Core.Retry with BackoffPolicy            | docs/plans/6-add-backoff-policy-module.md               | EP-1        | None      | Not Started |
| EP-3  | Populate attempt from pgmq readCount + Int32 clamp   | docs/plans/7-populate-attempt-from-pgmq-readcount.md    | EP-1        | EP-2      | Not Started |
| EP-4  | Demonstrate exponential backoff end-to-end           | docs/plans/8-demonstrate-backoff-end-to-end.md          | EP-2, EP-3  | None      | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.


## Dependency Graph

EP-1 is the foundation. It introduces `Attempt` and adds the `attempt :: !(Maybe
Attempt)` field on `Envelope`. Until that field exists, neither the policy module's
helpers (which are typed against `Envelope` for the convenience wrapper) nor the pgmq
adapter (which writes to the field) have something to bind against. Every in-tree
Envelope construction site is updated in EP-1 so that the codebase remains buildable
at the end of the plan.

EP-2 hard-depends on EP-1 because `retryWithBackoff` reads `envelope.attempt`. It does
not depend on EP-3: the policy module is pure and has no PGMQ dependency. EP-2 can be
landed on the desk of someone who has only `shibuya-core` checked out.

EP-3 hard-depends on EP-1 because the adapter's `pgmqMessageToEnvelope` must populate
the new field. EP-3 *soft-depends* on EP-2: the soft dependency is purely
documentation. The adapter's haddock mentions `retryWithBackoff` as the recommended
handler-side helper, which is more useful once EP-2 is real. If EP-3 lands first, the
haddock can be a `// TODO` referencing the future module name and updated when EP-2
arrives. There is no code-level dependency.

EP-2 and EP-3 can run in parallel once EP-1 is complete. They touch different files,
different test suites, different repositories.

EP-4 hard-depends on both EP-2 and EP-3 because the demonstration is a real consumer
that uses `retryWithBackoff` on a real PGMQ queue and observes the exponential
spacing. It is the integration moment for the whole initiative.

The shape of the dependency graph is a diamond:

        EP-1
         |
       /   \
     EP-2  EP-3
       \   /
        EP-4


## Integration Points

### IP-1: The `Envelope.attempt` field

Touched by: EP-1 (defines), EP-2 (reads via `retryWithBackoff`), EP-3 (writes from
pgmq `readCount`), EP-4 (observed in the demo handler).

What: A new field on `Envelope` of type `!(Maybe Attempt)`, where `Attempt` is a
newtype around `Word` defined in `Shibuya.Core.Types`. Semantics: `Just (Attempt 0)`
on the first delivery, `Just (Attempt 1)` on the first retry, and so on. `Nothing`
means the adapter cannot provide a delivery counter (e.g., a Kafka adapter where
offsets are not retries).

Defining plan: EP-1.

How later plans should consume or extend it:

- EP-2 reads via `envelope.attempt` (using `OverloadedRecordDot`) and treats
  `Nothing` as `Attempt 0` for backoff purposes (with a note in the haddock).
- EP-3 writes `attempt = Just (fromIntegral (msg.readCount - 1))` in
  `pgmqMessageToEnvelope`. pgmq increments `readCount` on read, so the first
  delivery sees `readCount = 1`; subtract one to land on the conventional 0-indexed
  retry counter. Use `max 0` defensively to handle the unexpected `readCount = 0`
  case.
- EP-4 destructures the field in a sample handler to log "delivery N" alongside the
  computed retry interval.

The `Attempt` newtype must derive `NFData` (consistent with the existing core types
that derive it; see `docs/plans/1-provide-nfdata-for-core-types.md`).


### IP-2: The `BackoffPolicy` type and `retryWithBackoff` helper

Touched by: EP-2 (defines), EP-3 (mentions in haddock), EP-4 (uses in the demo).

What: The user-facing record `BackoffPolicy { base, factor, maxDelay, jitter }` plus
the convenience function `retryWithBackoff :: (IOE :> es) => BackoffPolicy ->
Envelope msg -> Eff es AckDecision`. This is the API a handler author touches when
they want exponential backoff.

Defining plan: EP-2.

How later plans should consume or extend it:

- EP-3 mentions the helper in `Shibuya.Adapter.Pgmq` haddock as the recommended
  way to build retry decisions. No code-level dependency.
- EP-4 imports `Shibuya.Core.Retry` and uses `retryWithBackoff defaultBackoffPolicy
  ingested.envelope` in the demo handler.


### IP-3: Visibility-timeout `Int32` clamp

Touched by: EP-3 (defines and tests), implicitly relied on by EP-4 (demo could
configure a long `maxDelay`).

What: pgmq's `changeVisibilityTimeout` takes seconds as `Int32`. A `BackoffPolicy`
with a long `maxDelay` could theoretically overflow when converted via
`nominalToSeconds`. EP-3 adds a defensive clamp at the conversion boundary so that
unsafe configurations cannot crash the adapter — they merely cap at `Int32` max
seconds (about 68 years).

Defining plan: EP-3 (in `nominalToSeconds` or a new helper alongside it).

How later plans should consume or extend it: EP-4 should not need to think about
this at all. The clamp exists so the demo author cannot accidentally configure
something that explodes.


## Progress

- [x] EP-1: M1 — Add `Attempt` newtype to `Shibuya.Core.Types`. *(2026-04-29)*
- [x] EP-1: M2 — Add `attempt :: !(Maybe Attempt)` field to `Envelope` and update
      every in-tree construction site so the build stays green. *(2026-04-29)*
- [x] EP-1: M3 — Re-export `Attempt` from `Shibuya.Core` and update `CHANGELOG.md`
      with the breaking change. *(2026-04-29)*
- [ ] EP-2: M1 — Add `Shibuya.Core.Retry` module with `BackoffPolicy`, `Jitter`,
      `defaultBackoffPolicy`, and the pure evaluator `exponentialBackoffPure`.
- [ ] EP-2: M2 — Add the effectful evaluator `exponentialBackoff` (uses `IOE` to
      sample randomness) and the convenience `retryWithBackoff`.
- [ ] EP-2: M3 — Add property and unit tests covering monotonicity, max-delay
      clamping, and the boundary cases for each `Jitter` variant.
- [ ] EP-3: M1 — Populate `attempt` from `readCount` in `pgmqMessageToEnvelope`
      and add a unit test in `ConvertSpec` covering `readCount = 1, 2, 5`.
- [ ] EP-3: M2 — Add the defensive `Int32` clamp on visibility-timeout extension
      and a unit test that constructs a 100-year `RetryDelay` and asserts the
      adapter clamps to `Int32` max seconds without throwing.
- [ ] EP-3: M3 — Update `Shibuya.Adapter.Pgmq` haddock and `CHANGELOG.md` to
      mention the new field.
- [ ] EP-4: M1 — Write a handler in `shibuya-pgmq-example` that fails the first N
      deliveries and uses `retryWithBackoff`. Wire it into a runnable example.
- [ ] EP-4: M2 — Run the example against a local PGMQ-capable Postgres; capture
      timestamps that show the exponential spacing; record the transcript in the
      plan.
- [ ] EP-4: M3 — Update top-level `README.md` and the cross-cutting CHANGELOG
      entries with a worked snippet.


## Surprises & Discoveries

- EP-1's enumeration of `Envelope` construction sites missed the
  `shibuya-core-bench/` package (four additional sites in
  `bench/Bench/{Framework,Handler,Concurrency}.hs` and
  `bench/Test/StandaloneTest.hs`). They were updated to pass
  `attempt = Nothing`. Future ExecPlans that touch `Envelope` should
  grep with `'Envelope$\|Envelope {'` across all packages, not just
  `shibuya-core/` and `shibuya-example/`. Date: 2026-04-29.
- EP-1 M1's test snippet used `unAttempt (minBound :: Attempt)` as a
  function call. `shibuya-core` enables `NoFieldSelectors`, so field
  accessors are not in scope as functions. Fixed via record-dot
  syntax. EP-2 and EP-4 should be careful with field-selector idioms
  in any new test snippets they introduce. Date: 2026-04-29.


## Decision Log

- Decision: Put `attempt` on `Envelope` rather than on a new `DeliveryContext`
  record carried by `Ingested`.
  Rationale: Ergonomics. Handlers already destructure `ingested.envelope`, so
  putting the field there means `env.attempt` reads naturally. A separate record
  would touch every Envelope-destructuring call site for marginal type purity.
  The `Maybe` wrapper carries the "this adapter can't track it" case cleanly.
  Date: 2026-04-28.

- Decision: Newtype-wrap the attempt count as `Attempt = Attempt { unAttempt ::
  Word }` rather than using a raw `Int`.
  Rationale: Matches the codebase style (`MessageId`, `RetryDelay` are newtypes).
  Forecloses negative-attempt nonsense at the type level. `Word` over `Natural`
  because `Word` has the same fixed-size machine-int representation as the
  upstream `pgmq.readCount :: Int64` field — no allocation, no GMP dependency.
  Date: 2026-04-28.

- Decision: Provide `NoJitter`, `FullJitter`, `EqualJitter` initially. Defer
  `DecorrelatedJitter`.
  Rationale: `DecorrelatedJitter` requires the previous delay as input. Threading
  that through the handler signature changes the shape of the API
  (`retryWithBackoff` would have to take a previous-delay argument or the
  handler would have to track it). The three included variants cover the AWS
  "exponential backoff and jitter" published recommendation. Decorrelated can be
  added later without breaking the existing API by adding a new constructor and
  a parallel `retryWithBackoffDecorrelated` helper.
  Date: 2026-04-28.

- Decision: The effectful `exponentialBackoff` uses `(IOE :> es) => ... -> Eff
  es RetryDelay`, not raw `IO`.
  Rationale: Fits the project's effect system (`effectful`). All existing
  framework code is `Eff`-shaped; offering raw `IO` here would be the only
  exception. The pure variant `exponentialBackoffPure :: BackoffPolicy ->
  Attempt -> Double -> RetryDelay` (taking a `[0,1)` sample) is the testable
  core; `exponentialBackoff` just samples and calls it.
  Date: 2026-04-28.

- Decision: Add the defensive `Int32` clamp on the adapter side, not on the
  policy side.
  Rationale: The policy module produces `RetryDelay (NominalDiffTime)`, which is
  unbounded. The clamp is an adapter concern — different adapters might have
  different second-precision ceilings (SQS allows 12 hours, pgmq allows
  `Int32` seconds, etc.). Pushing the clamp into the policy would force the
  policy to know about every adapter's limit. The adapter is the natural place.
  Date: 2026-04-28.

- Decision: Reject the framework-evaluated alternative (`RetryDelay` as a sum
  type carrying a policy).
  Rationale: Per the original `EXPONENTIAL_BACKOFF_DESIGN.md` analysis: it
  pushes mechanics into `Shibuya.Core.Ack` contradicting its docstring
  ("Handlers decide meaning, not mechanics"); forces every adapter to track or
  fabricate an attempt counter; makes `RetryDelay` no longer fully owned by the
  handler (testing requires running through the framework). The handler-side
  approach we chose is strictly more flexible: a handler that wants
  framework-uniform backoff can call the same helper, while a handler that
  wants per-error-type policies (shorter for 429, longer for 503) can branch
  before calling.
  Date: 2026-04-28.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Reference

The original design notes that motivated this plan are at
`docs/plans/EXPONENTIAL_BACKOFF_DESIGN.md`. They remain in place as historical
context; this MasterPlan and its child ExecPlans supersede them for execution
purposes.
