---
id: 32
slug: add-application-defined-dead-letter-reasons
title: "Add application-defined dead-letter reasons"
kind: exec-plan
created_at: 2026-08-10T16:36:08Z
intention: "intention_01kzpb3grqe1a9r4qn7ad9fpqp"
---

# Add application-defined dead-letter reasons

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shibuya handlers can currently dead-letter a message only as a `PoisonPill`,
`InvalidPayload`, or `MaxRetriesExceeded`. A syntactically valid message can nevertheless be
permanently rejected by application policy—for example, a checked router may find more
recipients than its declared cap. Calling that message poison or invalid produces false
operator data. The source request is
`docs/improvement-requests/represent-application-defined-permanent-processing-failures-in-dead-letter-reasons.md`,
which originated from
`mori://shinzui/keiro/okf/improvement-requests/concepts/IR-9`.

After this plan is implemented, an application importing only the stable `Shibuya` umbrella
module can validate its stable code once during startup, pass the resulting value into its
handler, and return a decision such as:

```haskell
mkRouterHandler :: DeadLetterCode -> Handler es RouterMessage
mkRouterHandler recipientOverflowCode _message =
  pure $
    AckDeadLetter $
      ApplicationFailure
        recipientOverflowCode
        "selected 101 recipients; configured limit is 100"
```

The startup path calls
`mkDeadLetterCode "keiro.router.selection.recipient_overflow"` and refuses to start if it
returns `Left`; the per-message path receives the already validated `DeadLetterCode`.

The adapter finalizing that decision can obtain a stable code and optional detail through
total public functions; it does not need an exhaustive match over Shibuya constructors. The
single-message processing span exposes
`shibuya.dead_letter.reason.code = "keiro.router.selection.recipient_overflow"` and keeps the
human detail in its error status description. Existing poison, invalid-payload, and
retry-exhaustion text encodings remain byte-for-byte unchanged.

The behavior is demonstrated by pure API tests, a public-only compilation test, supervised
and batch finalization tests, an in-memory OpenTelemetry span test, the existing cross-version
`AckOk` throughput gate, and focused current-tree measurements of code validation and reason
rendering. The work culminates in the shared `shibuya-core`/`shibuya-metrics` 0.9.0.0 release
because extending the exported `DeadLetterReason` datatype is a breaking change under the
Haskell Package Versioning Policy (PVP). PVP calls the first two components `A.B` the major
version; changing a public datatype requires increasing `A.B`, so the successor to 0.8.0.1 is
0.9.0.0.


## Progress

- [x] Research the current public ack API, finalization contract, telemetry path, batch
      behavior, tests, known dependent renderers, PVP impact, and release process.
      (2026-08-10)
- [x] Create this ExecPlan and associate it with
      `intention_01kzpb3grqe1a9r4qn7ad9fpqp`. (2026-08-10)
- [x] M1: Add the validated `DeadLetterCode` API, `ApplicationFailure` reason, total
      code/detail projections, compatibility renderer, and public-only tests. The focused
      ack suite passed 18 examples, the public-only suite passed its example, and
      `cabal build shibuya-core` succeeded. (2026-08-10T17:27:23Z)
- [ ] M2: Use the canonical contract in supervised tracing, emit the stable reason-code
      span attribute, and prove supervised and batch finalization preserve the complete
      reason without changing acknowledgement mechanics.
- [ ] M3: Document the semantic and serialization contracts, write the 0.9 migration
      guide and unreleased changelog entries, and update the improvement request with the
      plan and corrected finalization/metrics wording.
- [ ] M4: Run formatting, build, tests, Haddock, package checks, flake checks, the mandatory
      0.8.0.1-to-current success-path benchmark comparison, and focused current-tree
      dead-letter code/rendering measurements; resolve any common-path regression and record
      the failure-path evidence before release.
- [ ] M5: After maintainer approval, release `shibuya-core` and `shibuya-metrics`
      0.9.0.0 in dependency order, create the git tag and GitHub release, and mark the
      improvement request released.


## Surprises & Discoveries

- The mechanical finalizer already transports the entire `AckDecision` to adapters:

  ```haskell
  finalize :: AckDecision -> Eff es ()
  ```

  Therefore no runner or adapter interface change is needed; this is an extension of the
  semantic value already crossing the boundary.

- The phrase “exactly-once finalization” in the source request is not the framework's actual
  contract. `shibuya-core/src/Shibuya/Core/AckHandle.hs` says one decision is resolved per
  delivery, but `finalize` may be invoked again with that same decision after a transient
  finalizer exception. Adapters must make those repeated attempts idempotent or
  phase-tracked.

- Core currently has a private exhaustive renderer in
  `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`. The PGMQ adapter independently
  duplicates the same match, as recorded by
  `mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1`, and
  `mori://shinzui/keiro/packages/keiro-pgmq` has another copy. A total core projection and
  renderer remove the reason for those copies.

- Current Shibuya metrics do not label failures by dead-letter reason.
  `metricForResult (Right (AckDeadLetter _))` produces only `CountFailed`. Adding
  application reasons therefore must not create a new reason-code metric label; doing so
  would introduce an unreviewed cardinality surface.

- A batch has one aggregate span but may contain several messages with different
  dead-letter reasons. Current batch tracing does not emit per-message reasons and reports a
  non-halt partial dead-letter batch as `Ok`. This plan proves reason preservation through
  finalization and deliberately does not invent a lossy “one reason per batch” attribute.

- As of 2026-08-10, the local package files, Hackage registry, and upstream release tags all
  identify 0.8.0.1 as the latest `shibuya-core` release. The repository release workflow
  releases `shibuya-core` before `shibuya-metrics` under one shared version and requires a
  benchmark comparison for every non-patch release.

- `shibuya-core-bench/bench/Bench/HotPath.hs` currently benchmarks only a handler returning
  `AckOk`, and it runs with `runTracingNoop`. That is the correct existing workload for
  detecting an accidental regression in the common success path, but it cannot measure the
  new reason renderer or the cost of a recorded OpenTelemetry attribute. The tracing effect
  deliberately skips attribute and status work when tracing is disabled.

- `tasty-bench` compares a current result with a CSV baseline only when the benchmark names
  match. A newly added reason benchmark has no result in the 0.8.0.1 CSV, so it must be
  reported as a current-tree measurement rather than presented as a cross-version result.
  Its `-T` output includes allocated, copied, and peak bytes. The dependency's baseline guide
  was verified through Mori at `mori://Bodigrim/tasty-bench/packages/tasty-bench`; it also
  recommends compiling both sides with `-fproc-alignment=64` to reduce cache-alignment noise.

- Extending `DeadLetterReason` immediately made the private supervised renderer
  non-exhaustive before M2's structured trace work began. The first focused build reported:

  ```text
  Pattern match(es) are non-exhaustive
  Patterns of type ‘DeadLetterReason’ not matched: ApplicationFailure _ _
  ```

  M1 therefore delegates that private compatibility helper to the new canonical renderer;
  M2 will remove the helper while adding the reason-code attribute.


## Decision Log

- Decision: The extension belongs in `shibuya-core`, not Keiro or an adapter.
  Rationale: `DeadLetterReason` is part of Shibuya's stable handler API and
  `AckHandle.finalize` passes it to every adapter. A downstream-only type could not travel
  through `AckDeadLetter` without lying through an existing constructor or changing the
  handler/adapter abstraction.
  Date: 2026-08-10

- Decision: Extend `DeadLetterReason` with
  `ApplicationFailure !DeadLetterCode !Text` rather than parameterizing
  `AckDecision`, replacing all reasons with free-form text, or adding domain constructors.
  Rationale: One application-defined escape hatch is the smallest change that preserves the
  meanings of the three built-in reasons and lets Shibuya remain unaware of consumer
  domains. Parameterization would make every handler, batch type, metric helper, and adapter
  signature polymorphic and is unnecessary for this use case.
  Date: 2026-08-10

- Decision: `DeadLetterCode` is opaque and is constructed by
  `mkDeadLetterCode :: Text -> Either Text DeadLetterCode`. A valid application code is at
  most 128 ASCII characters, contains at least two dot-separated segments, has each segment
  match `[a-z][a-z0-9_]*`, and does not use the reserved first segment `shibuya`.
  Rationale: A machine-facing code must not be empty, ambiguous with human prose, or collide
  with framework-owned future codes. Returning `Either Text` gives configuration and
  generated-code callers a useful failure without adding another public error datatype.
  Date: 2026-08-10

- Decision: Export total `deadLetterReasonCode`, `deadLetterReasonDetail`, and
  `renderDeadLetterReason` functions. Do not export a JSON instance or prescribe an adapter
  envelope.
  Rationale: Code/detail is transport-neutral and sufficient for JSON, Kafka headers,
  database columns, logging, and tracing. A core-owned JSON object would couple Shibuya to
  one adapter schema.
  Date: 2026-08-10

- Decision: Preserve the existing canonical tokens and rendered strings exactly:
  `poison_pill: <detail>`, `invalid_payload: <detail>`, and
  `max_retries_exceeded`. Render an application failure as
  `<application-code>: <detail>`.
  Rationale: The PGMQ adapter already persists the old strings in
  `dead_letter_reason`. Changing them is unnecessary wire-format breakage in addition to
  the unavoidable source-level constructor break.
  Date: 2026-08-10

- Decision: Put the application code in the
  `shibuya.dead_letter.reason.code` trace attribute and put the combined code/detail only
  in the span's error status description. Do not add detail as an attribute or add either
  value to metrics.
  Rationale: Codes are intended to be stable and queryable. Detail may contain
  high-cardinality operator context and, if callers violate documentation, sensitive text;
  duplicating it into attributes or metrics increases cost and disclosure risk.
  Date: 2026-08-10

- Decision: Batch processing must preserve the complete new reason in each retained
  message's finalization but receives no new aggregate reason attribute in this plan.
  Rationale: One batch span cannot truthfully represent an arbitrary set of per-message
  reasons with one scalar code. Designing per-message batch events is useful future work
  but is not required to carry the reason to adapters.
  Date: 2026-08-10

- Decision: Keep the hard performance gate on the pre-existing 0.8.0.1-to-current benchmark
  names, especially the `AckOk` hot path, with the existing 10% slowdown limit. Add focused
  current-tree measurements for application-code validation and built-in/application reason
  rendering, but do not impose a hard latency ratio on the uncommon dead-letter path.
  Rationale: The new constructor, projections, renderer, and trace attribute are reached only
  from `AckDeadLetter`; none belongs before the runner's decision match. Protecting the common
  success path is the release-critical concern. Failure-path measurements still catch
  accidental repeated validation, excessive text copying, and surprising allocation without
  treating the expected cost of diagnostics as equivalent to normal throughput.
  Date: 2026-08-10

- Decision: Validate application codes once during application startup and reuse the opaque
  value. Render a reason by extracting its code once and using `Text.concat` for the
  code/separator/detail form.
  Rationale: Validation is a bounded linear scan of at most 128 ASCII characters, but doing it
  for every failed message is needless. A single code extraction and `Text.concat`'s one
  destination allocation avoid the intermediate result created by chained `Text` appends
  while preserving the public projections as the canonical source of the rendering.
  Date: 2026-08-10

- Decision: Ship as 0.9.0.0 and release `shibuya-metrics` at the same version even though
  its API is unchanged.
  Rationale: Adding a constructor changes an exported datatype, so PVP requires an `A.B`
  bump. This repository releases its two Hackage packages under one shared version, and
  `shibuya-metrics` must update its `shibuya-core` bound.
  Date: 2026-08-10

- Decision: The adapter adoption and Keiro integration remain separate downstream work,
  tracked respectively by
  `mori://shinzui/shibuya-pgmq-adapter/okf/improvement-requests/concepts/IR-1` and
  `mori://shinzui/keiro/plans/230-make-declarative-dynamic-router-fan-out-first-class-in-keiro-dsl`.
  Rationale: Those repositories have independent tests, release cadences, and transport
  contracts. This plan produces the tagged public core prerequisite they consume.
  Date: 2026-08-10

- Decision: Make the supervised runner's existing private reason helper delegate to
  `renderDeadLetterReason` in M1, before the full M2 telemetry edit.
  Rationale: Adding the public constructor otherwise leaves an immediately reachable
  non-exhaustive match and a runtime failure in the milestone commit. Delegation preserves
  all old strings, renders the new constructor correctly, and does not precompute work on
  success paths. M2 still owns the structured code attribute and deletion of the helper.
  Date: 2026-08-10


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

All repository-relative paths below are relative to
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

Shibuya is a queue-processing framework. A handler receives a read-only `Message` and
returns an `AckDecision`. The decision says what the message means semantically:
`AckOk` succeeds, `AckRetry` requests redelivery, `AckDeadLetter` permanently disposes of
the message through a dead-letter queue or equivalent adapter operation, and `AckHalt`
stops the processor. An adapter is a package that translates those decisions into the
mechanics of a broker such as PostgreSQL PGMQ or Kafka.

`shibuya-core/src/Shibuya/Core/Ack.hs` defines the current public vocabulary:

```haskell
data DeadLetterReason
  = PoisonPill !Text
  | InvalidPayload !Text
  | MaxRetriesExceeded

data AckDecision
  = AckOk
  | AckRetry !RetryDelay
  | AckDeadLetter !DeadLetterReason
  | AckHalt !HaltReason
```

`shibuya-core/src/Shibuya.hs` is the stable umbrella module recommended to application
authors. It re-exports `DeadLetterReason(..)` and `AckDecision(..)`. New reason-code types
and functions must be exported there as well. `shibuya-core/src/Shibuya/Core.hs` simply
re-exports `Shibuya` as a deprecated compatibility module, so no separate edit is needed.

`shibuya-core/src/Shibuya/Core/AckHandle.hs` defines the adapter-provided mechanical
finalizer:

```haskell
newtype AckHandle es = AckHandle
  { finalize :: AckDecision -> Eff es ()
  }
```

The runner resolves one decision for a delivery. It normally calls `finalize` once, but
`shibuya-core/src/Shibuya/Internal/Runner/Finalize.hs` retries the same decision when the
adapter finalizer throws. “Preserved finalization behavior” in this plan therefore means
one resolved decision per delivery plus retry-idempotent attempts, not exactly one function
invocation.

`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` runs ordinary one-message handlers.
On `AckDeadLetter` it currently calls a local exhaustive `showDeadLetterReason` to set the
OpenTelemetry span's error description. That local helper emits the same three strings that
existing adapters use. This plan deletes the local helper and calls the new public
`renderDeadLetterReason` instead. It also attaches the stable application code through a
new semantic key.

`shibuya-core/src/Shibuya/Telemetry/Semantic.hs` owns Shibuya-specific OpenTelemetry wire
keys such as `shibuya.ack.decision`. Add
`attrShibuyaDeadLetterReasonCode = "shibuya.dead_letter.reason.code"` here. The existing
wire-format tests in `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs` use
`hs-opentelemetry-exporter-in-memory` to run a real processor, read the exported span's
`spanHot` reference, inspect `hotAttributes`, and inspect `hotStatus`. Reuse that pattern.
The dependency source and guides were located through Mori at
`mori://iand675/hs-opentelemetry/packages/hs-opentelemetry-api` and
`mori://iand675/hs-opentelemetry/packages/hs-opentelemetry-exporter-in-memory`; no dependency
version change is required.

`shibuya-core/src/Shibuya/Batch.hs` exposes `failMessages`, while
`shibuya-core/src/Shibuya/Internal/Runner/BatchProcessor.hs` resolves a `BatchAck` into one
decision for every retained message and sends each decision to its own finalizer. The
existing tests in `shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs` use tracking
finalizers to prove exact decision preservation. Extend those tests with an application
failure. Do not change batch resolution, retries, metrics, or aggregate span status.

`shibuya-core/test/Shibuya/Core/AckSpec.hs` covers the pure ack types but imports
`Shibuya.Core.Ack` directly. Add
`shibuya-core/test/Shibuya/PublicApiSpec.hs`, importing only `Shibuya` plus test-library
modules, to prove an application can construct, return, project, and render the new reason
without importing an internal or component module. Register every new test module in
`shibuya-core/test/Main.hs` and the test suite's `other-modules` list in
`shibuya-core/shibuya-core.cabal`.

The current user-facing descriptions live in:

- `docs/architecture/CORE_TYPES.md` for the data model.
- `docs/user/getting-started.md` for handler examples.
- `docs/user/opentelemetry.md` for span keys and data-safety guidance.
- `docs/user/README.md` for the user-guide index.
- `shibuya-core/CHANGELOG.md` and root `CHANGELOG.md` for release notes.

`docs/TASKS.md` also contains the original three-constructor datatype, but its first
paragraph marks it as a historical document and warns readers not to copy its signatures.
Do not rewrite historical plans or `docs/TASKS.md`; migration documentation is the source
of truth for the new release.

This is a Cabal multi-package repository. `shibuya-core/shibuya-core.cabal` and
`shibuya-metrics/shibuya-metrics.cabal` are both version 0.8.0.1.
`shibuya-metrics` depends on `shibuya-core ^>=0.8.0.1`. The example and benchmark packages
are not published and retain their independent 0.1.0.0 versions. At release, bump the two
published packages and the internal bound to 0.9.0.0.

`shibuya-core-bench/bench/Bench/HotPath.hs` is the common-path performance guard: its
handlers return `AckOk` for 10,000 messages under serial and asynchronous concurrency.
`shibuya-core-bench/shibuya-core-bench.cabal` enables RTS statistics with `-T`, so benchmark
reports include allocation as well as time. Add a separate
`shibuya-core-bench/bench/Bench/DeadLetterReason.hs` group for the bounded validator and pure
renderer. Keep those measurements separate from `Bench.HotPath`, and do not change the
existing success workloads merely to exercise the new failure feature. The in-memory
OpenTelemetry test remains a correctness test rather than a latency gate: exporter and
backend costs are environment-specific, and a recorded dead-letter is already an exceptional
path.

Terms used in the rest of the plan:

A **dead-letter code** is a short, machine-queryable identifier whose meaning remains stable
across deployments. **Detail** is human-readable operator context for one occurrence. A
**canonical renderer** converts either built-in or application reasons into the existing
single-text representation used by traces and legacy DLQ fields. A **public-only test**
imports the `Shibuya` umbrella rather than `Shibuya.Core.Ack` or any
`Shibuya.Internal.*` module. A **source distribution** (sdist) is the tarball Cabal uploads
to Hackage.


## Plan of Work

The work has five milestones. M1 creates the pure public contract; M2 threads it through
existing runtime observability and proves finalization; M3 makes the contract consumable and
migratable; M4 runs all local release gates; M5 publishes the required release. Each
milestone must update Progress, record discoveries and decisions, and leave the tree
buildable.

### Milestone 1 — Define and prove the public semantic contract

Edit `shibuya-core/src/Shibuya/Core/Ack.hs`. Under the dead-letter export group, export the
opaque `DeadLetterCode` type, `mkDeadLetterCode`, `deadLetterCodeText`,
`DeadLetterReason(..)`, `deadLetterReasonCode`, `deadLetterReasonDetail`, and
`renderDeadLetterReason`.

Implement the final interface shown in Interfaces and Dependencies. Keep
`DeadLetterCode`'s data constructor private. `mkDeadLetterCode` validates the rules in the
Decision Log using only `base` and `text`; do not add a parser dependency. Its work must be
one bounded linear scan or an equivalently bounded collection of simple scans over the
at-most-128-character input, never a regex with uncontrolled backtracking. Error messages
must name the rejected code and the failed rule but are operator diagnostics, not stable
machine codes.

Add `ApplicationFailure !DeadLetterCode !Text` to `DeadLetterReason`. Preserve the existing
constructor order and definitions. Implement the projections as exhaustive matches with no
wildcard. Construct framework-owned built-in `DeadLetterCode` values privately:
`poison_pill`, `invalid_payload`, and `max_retries_exceeded`. Implement the renderer from the
public projections so code/detail formatting has one definition:

```haskell
renderDeadLetterReason reason =
  let code = deadLetterCodeText (deadLetterReasonCode reason)
   in case deadLetterReasonDetail reason of
        Nothing -> code
        Just detail -> Text.concat [code, ": ", detail]
```

Add Haddocks that distinguish application policy from payload parsing, poison messages, and
retry exhaustion. State that the application owns code stability; detail is transported
verbatim and must not contain secrets, unrestricted backend error text, raw SQL, or full
payloads. Tell applications to validate a finite set of codes during startup, retain the
opaque values in configuration, and reuse them rather than calling `mkDeadLetterCode` for
every message.

Update `shibuya-core/src/Shibuya.hs` to re-export all new public types and functions.

Expand `shibuya-core/test/Shibuya/Core/AckSpec.hs` with examples for valid codes, every
invalid grammar boundary, total projections for all four constructors, exact legacy
rendering, and application rendering. Create
`shibuya-core/test/Shibuya/PublicApiSpec.hs` with an import of `Shibuya` only. It should
define a small public handler returning the new reason, run it far enough to inspect the
value, and assert that `deadLetterReasonCode`, `deadLetterReasonDetail`, and
`renderDeadLetterReason` are available from the umbrella module. Register the module in
`shibuya-core/test/Main.hs` and `shibuya-core/shibuya-core.cabal`.

Acceptance for M1: the focused ack and public API tests pass; old render strings remain
exact; malformed and reserved codes are rejected; and the public test contains no
`Shibuya.Core.*` or `Shibuya.Internal.*` import.

### Milestone 2 — Integrate tracing and prove decision preservation

Edit `shibuya-core/src/Shibuya/Telemetry/Semantic.hs` to export and define
`attrShibuyaDeadLetterReasonCode`. Extend
`shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`'s wire-format assertions so the literal
key cannot drift unnoticed.

In `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs`, import the public projection
and renderer. In the successful-finalization `AckDeadLetter reason` branch, attach
`deadLetterCodeText (deadLetterReasonCode reason)` under
`attrShibuyaDeadLetterReasonCode`, then set `OTel.Error` using
`renderDeadLetterReason reason`. Delete the local `showDeadLetterReason`. Do not add the
detail as an attribute and do not change `attrShibuyaAckDecision`, metrics, handler
exception behavior, or finalizer retry. Keep both new computations syntactically inside the
`AckDeadLetter` branch; do not precompute a reason code or rendered status before matching
the decision. Consequently an `AckOk` or `AckRetry` executes neither projection, rendering,
nor the new attribute call.

Add an in-memory exporter test to
`shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs` that processes exactly one message
whose handler returns:

```haskell
AckDeadLetter
  (ApplicationFailure code "selected 101 recipients; configured limit is 100")
```

After shutting down the tracer provider, assert one span, the existing
`shibuya.ack.decision = "ack_dead_letter"` attribute, the new reason-code attribute, and:

```text
Error "keiro.router.selection.recipient_overflow: selected 101 recipients; configured limit is 100"
```

Extend `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` or the public API test to use a
tracking finalizer and prove the full `ApplicationFailure` value reaches `finalize`.
Extend `shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs` so one explicit override and
one fallback path use application failures and the tracker observes exactly the decisions
resolved by the framework. Assert existing processed/failed and partial-failure counters;
do not add a reason-keyed metric.

Acceptance for M2: the in-memory span carries the structured code and rendered status, both
ordinary and batch paths deliver the exact reason to their adapter finalizers, transient
finalizer retry tests remain green, and metric counts are unchanged.

### Milestone 3 — Document compatibility, migration, and downstream ownership

Update `docs/architecture/CORE_TYPES.md` with the new type, constructor, code grammar,
projection functions, and handler/adapter ownership boundary. Update
`docs/user/getting-started.md` with a valid-message application-failure example and explain
when each of the four constructors is truthful. Update `docs/user/opentelemetry.md` with the
new trace key, status-rendering behavior, the “no secrets in detail” rule, and the explicit
statement that reason code/detail are not metric labels. The getting-started example must
validate codes once before starting a processor, and the telemetry guide must forbid request
IDs, message IDs, timestamps, or other occurrence-specific values in a code. Recommend a
small stable application-owned code taxonomy and operationally bounded details; Shibuya does
not impose a new detail limit because the existing built-in detail constructors already
accept `Text`.

Create `docs/user/migrating-to-0.9.md`. It must explain that adding the constructor is
source-breaking for exhaustive matches, show how adapter code changes from:

```haskell
case reason of
  PoisonPill detail -> ...
  InvalidPayload detail -> ...
  MaxRetriesExceeded -> ...
```

to:

```haskell
let code = deadLetterCodeText (deadLetterReasonCode reason)
    detail = deadLetterReasonDetail reason
    rendered = renderDeadLetterReason reason
```

Document that `Show` is not a wire format, the old canonical strings remain stable, and
adapters should store code and detail separately when their schema permits while retaining
legacy fields according to their own migration policy. Link this guide from
`docs/user/README.md`.

Add `## Unreleased` entries to `shibuya-core/CHANGELOG.md` and root `CHANGELOG.md` under
Breaking Changes and New Features. State that downstream `^>=0.8` bounds intentionally
exclude 0.9 and must be reviewed. Do not update the historical `docs/TASKS.md` or snapshot
prose in completed ExecPlans.

Revise
`docs/improvement-requests/represent-application-defined-permanent-processing-failures-in-dead-letter-reasons.md`
so its frontmatter links `plan: docs/plans/32-add-application-defined-dead-letter-reasons.md`
and its status becomes `accepted` while implementation/release are pending. Replace
“exactly-once acknowledgement/finalization” with “one resolved decision per delivery and
retry-idempotent finalization.” Replace the claim that current reason metrics are inaccurate
with the accurate scope: DLQ payloads, traces, logs, and operator explanations. Tighten
acceptance to require the total structured projections, exact legacy rendering, structured
trace code, safe-detail documentation, and the 0.9 PVP consequence. After M5 publishes the
release, change the request to `status: released` and add the tagged version and Hackage
artifact to its Status prose.

Acceptance for M3: a novice can choose the right reason, write a public-only handler,
migrate an exhaustive adapter match, predict every canonical string, find the trace code,
and understand why the release is 0.9.0.0 without consulting another repository.

### Milestone 4 — Run local release gates and targeted performance checks

Format the tree, build all local packages, run all core tests, build Haddock, run Cabal
package checks, and run the flake checks using the commands in Concrete Steps. New files
must be staged before `nix flake check` because Nix evaluates the git tree.

Before running the comparison, create
`shibuya-core-bench/bench/Bench/DeadLetterReason.hs`, register it in
`shibuya-core-bench/bench/Main.hs` and `shibuya-core-bench/shibuya-core-bench.cabal`, and
briefly document it in `shibuya-core-bench/README.md`. Include three pure measurements: a
representative `keiro.router.selection.recipient_overflow` code passed to `mkDeadLetterCode`,
`renderDeadLetterReason (PoisonPill typicalDetail)`, and
`renderDeadLetterReason (ApplicationFailure representativeCode typicalDetail)`. Use a
top-level, already validated `representativeCode` for the render measurement so validation is
not accidentally charged to every reason. The validation measurement is intentionally
separate. Force each rendered `Text` to normal form so allocation is visible.

Because 0.9.0.0 is a major release, capture a benchmark baseline from the annotated
`v0.8.0.1` tag in a detached temporary worktree, then compare matching pre-existing
benchmarks with a 10% slowdown threshold. Compile both runs with
`-fproc-alignment=64`. This is the hard gate that protects `AckOk` and other existing
workloads. Then run the new `dead-letter-reason` group on the current tree and record its
time, allocated bytes, and copied bytes. It has no 0.8.0.1 benchmark with the same name and
therefore is evidence, not a cross-version threshold. There is no hard relative limit
between `PoisonPill` and `ApplicationFailure`; investigate only surprising allocation,
nonlinear behavior, repeated validation in the render benchmark, or a result inconsistent
with one bounded code scan and one output allocation plus linear copying.

Record concise evidence in Surprises & Discoveries. If a matching pre-existing benchmark
has a repeatable regression, stop before release; either remove it or obtain explicit
maintainer acceptance and record the tradeoff in this plan and the changelog. A slower
dead-letter measurement alone is not a release blocker when the implementation remains
bounded and its cost is explained by the additional diagnostic value.

Acceptance for M4: all local validation commands pass, Haddock includes every new export,
the pre-existing benchmark comparison has no unexplained regression above the threshold,
the focused dead-letter timing/allocation evidence is recorded and structurally bounded,
and `git diff --check` reports no whitespace errors.

### Milestone 5 — Release 0.9.0.0 and close the request

This milestone changes external state. Before editing final versions or publishing, present
the proposed version and all changelog entries to the maintainer and obtain confirmation.
Then bump both published packages to 0.9.0.0, update the `shibuya-metrics` core bound to
`^>=0.9.0.0`, date all three changelogs, and rerun the full M4 validation plus source
distribution checks.

Commit with the required ExecPlan and Intention trailers, create annotated tag
`v0.9.0.0`, and—with explicit authorization—push the commit and tag. Publish
`shibuya-core` before `shibuya-metrics` because metrics depends on core. Do not publish
metrics if the core upload fails. Publish Haddock documentation for both, create the GitHub
release with Hackage links, and verify the registry pages. Finally mark the improvement
request released and update this plan's Progress and Outcomes & Retrospective. If that final
documentation change occurs after the release tag, commit it as a small follow-up with both
trailers rather than moving the published tag.

Acceptance for M5: `v0.9.0.0` resolves upstream; Hackage contains both packages and their
documentation; a downstream project can declare `shibuya-core ^>=0.9.0.0` and import the
new public API; and the improvement request records the released artifact.


## Concrete Steps

Run all commands from:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
git status --short
```

The working tree already contained user-owned changes when this plan was written. Preserve
them and stage only files belonging to the active milestone. Never reset or restore an
unrelated path.

For M1, after editing the API and tests:

```bash
nix fmt
cabal test shibuya-core-test --test-options='--match "Shibuya.Core.Ack"'
cabal test shibuya-core-test --test-options='--match "Shibuya.PublicApi"'
cabal build shibuya-core
```

Expected focused result:

```text
0 failures
Test suite shibuya-core-test: PASS
```

Before committing M1/M2, verify the public test really uses only the umbrella:

```bash
rg -n '^import Shibuya( |$)' shibuya-core/test/Shibuya/PublicApiSpec.hs
rg -n 'Shibuya\\.Core|Shibuya\\.Internal' shibuya-core/test/Shibuya/PublicApiSpec.hs
```

The first command must show the `Shibuya` import; the second must print nothing.

For M2:

```bash
nix fmt
cabal test shibuya-core-test --test-options='--match "Shibuya.Telemetry.Semantic"'
cabal test shibuya-core-test --test-options='--match "Shibuya.Internal.Runner.Supervised"'
cabal test shibuya-core-test --test-options='--match "Shibuya.Internal.Runner.BatchProcessor"'
cabal test shibuya-core-test
```

If Hspec matching differs under the installed version, run the complete test suite rather
than weakening validation. The complete suite must report zero failures.

After M1 is green, update this plan's living sections and commit the pure contract:

```text
feat(core)!: add application-defined dead-letter reasons

Add validated application reason codes, total adapter-facing projections,
canonical rendering, and public-only contract tests.

BREAKING CHANGE: DeadLetterReason gains ApplicationFailure; exhaustive
matches must handle it or use the new total projections.

ExecPlan: docs/plans/32-add-application-defined-dead-letter-reasons.md
Intention: intention_01kzpb3grqe1a9r4qn7ad9fpqp
```

After M2 is green, update the living sections again and commit the runtime integration:

```text
feat(telemetry): expose application dead-letter reason codes

Use the canonical reason contract in processing spans and prove ordinary
and batch finalizers preserve the complete application reason.

ExecPlan: docs/plans/32-add-application-defined-dead-letter-reasons.md
Intention: intention_01kzpb3grqe1a9r4qn7ad9fpqp
```

For M3:

```bash
rg -n 'DeadLetterReason|ApplicationFailure|deadLetterReasonCode|deadLetter_reason|dead_letter_reason' \
  README.md docs/architecture docs/user shibuya-core/CHANGELOG.md CHANGELOG.md
rg -n '^status:|^plan:' \
  docs/improvement-requests/represent-application-defined-permanent-processing-failures-in-dead-letter-reasons.md
nix fmt
git diff --check
```

Suggested documentation commit:

```text
docs(core): document application dead-letter reasons

Document code/detail semantics, telemetry safety, adapter serialization,
the 0.9 migration, and the accepted upstream improvement request.

ExecPlan: docs/plans/32-add-application-defined-dead-letter-reasons.md
Intention: intention_01kzpb3grqe1a9r4qn7ad9fpqp
```

For the local M4 gate:

```bash
nix fmt
cabal build all
cabal test shibuya-core-test --test-show-details=direct
cabal haddock shibuya-core
(cd shibuya-core && cabal check)
(cd shibuya-metrics && cabal check)
git add \
  docs/architecture/CORE_TYPES.md \
  docs/improvement-requests/represent-application-defined-permanent-processing-failures-in-dead-letter-reasons.md \
  docs/plans/32-add-application-defined-dead-letter-reasons.md \
  docs/user/README.md \
  docs/user/getting-started.md \
  docs/user/migrating-to-0.9.md \
  docs/user/opentelemetry.md \
  shibuya-core/CHANGELOG.md \
  shibuya-core/shibuya-core.cabal \
  shibuya-core/src/Shibuya.hs \
  shibuya-core/src/Shibuya/Core/Ack.hs \
  shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs \
  shibuya-core/src/Shibuya/Telemetry/Semantic.hs \
  shibuya-core/test/Main.hs \
  shibuya-core/test/Shibuya/Core/AckSpec.hs \
  shibuya-core/test/Shibuya/PublicApiSpec.hs \
  shibuya-core/test/Shibuya/Runner/BatchProcessorSpec.hs \
  shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs \
  shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs \
  shibuya-core-bench/README.md \
  shibuya-core-bench/bench/Bench/DeadLetterReason.hs \
  shibuya-core-bench/bench/Main.hs \
  shibuya-core-bench/shibuya-core-bench.cabal \
  CHANGELOG.md
nix flake check
git diff --cached --check
```

Adjust the `git add` paths to the actual milestone diff; do not stage unrelated changes.
The expected final lines include:

```text
Test suite shibuya-core-test: PASS
```

Implement the focused benchmark as a separate group. The essential definitions are:

```haskell
module Bench.DeadLetterReason (benchmarks) where

import Data.Text (Text)
import Shibuya
  ( DeadLetterCode,
    DeadLetterReason (..),
    mkDeadLetterCode,
    renderDeadLetterReason,
  )
import Test.Tasty.Bench (Benchmark, bench, bgroup, nf, whnf)

benchmarks :: Benchmark
benchmarks =
  bgroup
    "dead-letter-reason"
    [ bench "validate-application-code" $
        whnf mkDeadLetterCode applicationCodeText,
      bench "render-poison-pill" $
        nf renderDeadLetterReason (PoisonPill typicalDetail),
      bench "render-application-failure" $
        nf
          renderDeadLetterReason
          (ApplicationFailure applicationCode typicalDetail)
    ]

applicationCodeText :: Text
applicationCodeText = "keiro.router.selection.recipient_overflow"

applicationCode :: DeadLetterCode
applicationCode =
  case mkDeadLetterCode applicationCodeText of
    Left err -> error ("invalid benchmark fixture: " <> show err)
    Right code -> code

typicalDetail :: Text
typicalDetail = "selected 101 recipients; configured limit is 100"
```

Import this module qualified in `shibuya-core-bench/bench/Main.hs`, append its `benchmarks`
value to `defaultMain`, and add `Bench.DeadLetterReason` to the Cabal benchmark's
`other-modules`. `Text` already has the required normal-form instance through the existing
benchmark dependencies, so no package bound changes are necessary.

Run the required benchmark comparison. `mktemp` creates a narrow temporary directory and
`git worktree remove` cleans it without touching the active tree. Passing the same GHC
procedure-alignment option to both builds reduces layout noise:

```bash
benchmark_root=$(mktemp -d /tmp/shibuya-ep32-benchmark.XXXXXX)
baseline_tree="$benchmark_root/v0.8.0.1"
baseline_csv="$benchmark_root/baseline.csv"
dead_letter_csv="$benchmark_root/dead-letter-reason.csv"

git worktree add "$baseline_tree" v0.8.0.1
(
  cd "$baseline_tree"
  cabal bench shibuya-core-bench --ghc-options=-fproc-alignment=64 \
    --benchmark-options="--csv $baseline_csv --stdev 5 --timeout 120"
)
cabal bench shibuya-core-bench --ghc-options=-fproc-alignment=64 \
  --benchmark-options="--baseline $baseline_csv --fail-if-slower 10 --stdev 5 --timeout 120"
cabal bench shibuya-core-bench --ghc-options=-fproc-alignment=64 \
  --benchmark-options="-p dead-letter-reason --csv $dead_letter_csv --stdev 5 --timeout 120"
git worktree remove "$baseline_tree"
```

If the comparison fails near the noise threshold, repeat it on an idle machine with
`--stdev 3` and a larger timeout. The `--fail-if-slower` result applies only to names found
in `baseline.csv`; do not describe the newly named group as a 0.8.0.1 comparison. Record the
serial and asynchronous `AckOk` results plus all three focused measurements, including
allocated and copied bytes, in Surprises & Discoveries before deciding.

After maintainer approval, perform the M5 release edits and rerun:

```bash
rg -n '^version:|shibuya-core \\^>=' \
  shibuya-core/shibuya-core.cabal shibuya-metrics/shibuya-metrics.cabal
cabal build all
cabal test shibuya-core-test --test-show-details=direct
nix fmt
nix flake check
cabal sdist shibuya-core shibuya-metrics
```

The version check must show 0.9.0.0 for both published packages and
`shibuya-core ^>=0.9.0.0` in metrics. Inspect the source distributions:

```bash
tar -xzf dist-newstyle/sdist/shibuya-core-0.9.0.0.tar.gz -O \
  shibuya-core-0.9.0.0/shibuya-core.cabal | sed -n '1,8p'
tar -xzf dist-newstyle/sdist/shibuya-metrics-0.9.0.0.tar.gz -O \
  shibuya-metrics-0.9.0.0/shibuya-metrics.cabal | sed -n '1,8p'
```

The release commit must be Conventional Commits compliant and carry both trailers:

```text
chore(release): release shibuya packages 0.9.0.0

Release the application-defined dead-letter reason contract and bump
shibuya-metrics in lockstep with the breaking shibuya-core API.

ExecPlan: docs/plans/32-add-application-defined-dead-letter-reasons.md
Intention: intention_01kzpb3grqe1a9r4qn7ad9fpqp
```

Only after the maintainer confirms the final diff and authorizes external publication:

```bash
git tag -a v0.9.0.0 -m "Release 0.9.0.0"
git push
git push origin v0.9.0.0

cd shibuya-core
cabal check
cabal upload --publish ../dist-newstyle/sdist/shibuya-core-0.9.0.0.tar.gz
cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump
# Upload the generated documentation tarball reported by Cabal.

cd ../shibuya-metrics
cabal check
cabal upload --publish ../dist-newstyle/sdist/shibuya-metrics-0.9.0.0.tar.gz
cabal haddock --haddock-for-hackage --haddock-hyperlink-source --haddock-quickjump
# Upload the generated documentation tarball reported by Cabal.
```

Use `cabal upload --publish --documentation <reported-docs-tarball>` for each documentation
archive. Then create the GitHub release from the root changelog, including direct Hackage
links for both packages:

```bash
gh release create v0.9.0.0 \
  --title "v0.9.0.0" \
  --notes-file /tmp/shibuya-0.9.0.0-release-notes.md
```

Write the temporary notes file from the 0.9.0.0 section of `CHANGELOG.md` and prepend links
to `https://hackage.haskell.org/package/shibuya-core-0.9.0.0` and
`https://hackage.haskell.org/package/shibuya-metrics-0.9.0.0`. Verify the published pages
and the URL returned by `gh release create` before marking Progress complete.


## Validation and Acceptance

The feature is accepted only when all of the following observable behaviors hold.

1. A module importing only `Shibuya` can validate
   `keiro.router.selection.recipient_overflow`, construct
   `ApplicationFailure` with a human detail, and return it in `AckDeadLetter`.

2. `mkDeadLetterCode` accepts namespaced lowercase codes such as the Keiro example and
   rejects empty, over-128-character, unqualified, uppercase, punctuation-bearing,
   empty-segment, digit-leading-segment, and `shibuya`-namespace values.

3. For built-in reasons, the projections and renderer yield exactly:

   ```text
   PoisonPill "x"       -> code "poison_pill", detail Just "x", "poison_pill: x"
   InvalidPayload "x"   -> code "invalid_payload", detail Just "x", "invalid_payload: x"
   MaxRetriesExceeded   -> code "max_retries_exceeded", detail Nothing, "max_retries_exceeded"
   ```

   For the application example they yield code
   `keiro.router.selection.recipient_overflow`, the original detail, and
   `keiro.router.selection.recipient_overflow: <detail>`.

4. An ordinary handler and a batch handler deliver an `ApplicationFailure` unchanged to
   tracking `AckHandle` finalizers. Existing transient-finalizer tests still demonstrate
   that retries repeat the same decision and record one successful completion.

5. The real in-memory OpenTelemetry test exports one processing span with
   `shibuya.ack.decision = ack_dead_letter`,
   `shibuya.dead_letter.reason.code = keiro.router.selection.recipient_overflow`, and the
   exact rendered `Error` status. No detail attribute or reason-keyed metric is emitted.

6. Existing failed-message, batch partial-failure, processed, and finalization-failure
   counters retain their values. No test or production metric series gains the application
   code as a label.

7. The migration guide tells every exhaustive matcher why 0.9 is source-breaking and how
   to replace the match with total projections. The existing legacy render strings remain
   documented as stable.

8. The new projection, rendering, and trace-attribute operations remain inside the
   `AckDeadLetter` decision branch. Matching pre-existing benchmark names, including both
   10,000-message `AckOk` hot-path workloads, have no unexplained slowdown above 10% versus
   0.8.0.1. The current-tree dead-letter benchmark records validation and rendering time,
   allocated bytes, and copied bytes; its render fixture reuses an already validated code.

9. `nix fmt`, `cabal build all`, `cabal test shibuya-core-test`,
   `cabal haddock shibuya-core`, both `cabal check` commands, `nix flake check`, and
   `git diff --check` succeed.

10. After the gated release, upstream tag `v0.9.0.0`, Hackage
   `shibuya-core-0.9.0.0`, Hackage `shibuya-metrics-0.9.0.0`, their Haddocks, and the
   GitHub release all resolve. The source improvement request records `status: released`.

The downstream PGMQ structured-JSON migration and Keiro router use are not acceptance gates
for this core plan. They start only after the tagged core artifact exists and remain governed
by their canonical cross-repository improvement request and ExecPlan URIs.


## Idempotence and Recovery

All source edits, formatting, builds, tests, Haddock generation, package checks, and
benchmarks are safe to repeat. The new API is additive in implementation even though it is
source-breaking for exhaustive clients. There is no database migration and no destructive
wire rewrite. Existing built-in rendered values remain unchanged, so a rollback before
release simply removes the new constructor and helpers.

The benchmark uses a detached worktree so it never checks out another revision over active
changes. If a benchmark command fails, run `git worktree list`, then remove only the exact
temporary baseline path created by this plan with `git worktree remove <path>`. Keep the CSV
until evidence is recorded.

If a pre-commit hook formats files, review the formatter's changes, stage only the plan's
paths again, and retry the commit. Never use `git reset --hard` or restore unrelated
user-owned changes.

Creating a git tag, pushing, publishing to Hackage, and creating a GitHub release change
external state. They require the explicit maintainer gate in M5. Before tagging, verify
`git tag --list v0.9.0.0` is empty. If it is not empty, inspect the existing tag and stop;
do not move or overwrite a published tag.

Hackage releases are immutable. Upload `shibuya-core` first and verify it before uploading
`shibuya-metrics`. If core publication fails, do not publish metrics. If core succeeds and
metrics fails, leave the successful core release intact, fix only the metrics packaging
problem, rebuild the identical 0.9.0.0 metrics artifact, and retry metrics; do not republish
core or retag. If documentation upload fails after a package source upload succeeds, retry
only the documentation upload for that exact package/version.


## Interfaces and Dependencies

`shibuya-core/src/Shibuya/Core/Ack.hs` must expose this final public interface:

```haskell
newtype DeadLetterCode = DeadLetterCode Text
  deriving stock (Eq, Ord, Show)

mkDeadLetterCode :: Text -> Either Text DeadLetterCode

deadLetterCodeText :: DeadLetterCode -> Text

data DeadLetterReason
  = PoisonPill !Text
  | InvalidPayload !Text
  | MaxRetriesExceeded
  | ApplicationFailure !DeadLetterCode !Text
  deriving stock (Eq, Show, Generic)

deadLetterReasonCode :: DeadLetterReason -> DeadLetterCode

deadLetterReasonDetail :: DeadLetterReason -> Maybe Text

renderDeadLetterReason :: DeadLetterReason -> Text
```

The `DeadLetterCode` constructor in that declaration is illustrative of the internal
representation and must not appear in the module export list. Do not derive `Generic` for
this newtype because `GHC.Generics.to` would provide a construction path that bypasses the
validator. `deadLetterCodeText` is the only public unwrapping operation. `Shibuya`
re-exports the opaque type and all five helper functions plus `DeadLetterReason(..)`.

The valid application-code grammar is:

```text
code       = segment "." segment ("." segment)*
segment    = lower-ascii-letter (lower-ascii-letter | digit | "_")*
max length = 128 ASCII characters
reserved   = first segment "shibuya"
```

The three framework codes are private values that do not go through the application
grammar because their historic tokens are intentionally unqualified.

`shibuya-core/src/Shibuya/Telemetry/Semantic.hs` must export:

```haskell
attrShibuyaDeadLetterReasonCode :: Text
attrShibuyaDeadLetterReasonCode = "shibuya.dead_letter.reason.code"
```

No new Hackage dependency is needed. Validation uses `Data.Char` from `base` and
`Data.Text` from the existing `text` dependency. Telemetry uses the already-declared
`hs-opentelemetry-api ^>=1.0` and test-only
`hs-opentelemetry-exporter-in-memory ^>=1.0`. Their relevant source APIs were verified
through Mori rather than inferred.

The performance contract is deliberately asymmetric. `AckOk` and `AckRetry` must not call
`deadLetterReasonCode`, `deadLetterReasonDetail`, or `renderDeadLetterReason`, and must not
add `attrShibuyaDeadLetterReasonCode`; the existing common-path benchmarks enforce that no
unexplained regression escapes. `AckDeadLetter` may perform one code projection, one
output-sized render, and—when tracing is enabled—one additional span-attribute update.
Application code validation is bounded by the 128-character grammar and belongs at startup,
not in the handler loop. Detail remains unbounded for compatibility with existing
constructors, so applications are responsible for keeping it operationally small.

The mechanical boundary remains unchanged:

```haskell
newtype AckHandle es = AckHandle
  { finalize :: AckDecision -> Eff es ()
  }
```

The downstream serialization contract is deliberately representation-neutral:

```haskell
deadLetterCodeText (deadLetterReasonCode reason) :: Text
deadLetterReasonDetail reason                    :: Maybe Text
renderDeadLetterReason reason                    :: Text
```

An adapter that has structured storage should persist the first two values separately. A
legacy adapter that has only one text field can persist `renderDeadLetterReason`. Neither
adapter needs to match on `PoisonPill`, `InvalidPayload`, `MaxRetriesExceeded`, or
`ApplicationFailure`.

The release interface is `shibuya-core 0.9.0.0` plus `shibuya-metrics 0.9.0.0`, with
`shibuya-metrics` declaring `shibuya-core ^>=0.9.0.0`. The canonical downstream package
references are `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` and
`mori://shinzui/keiro/packages/keiro-dsl`.


## Revision Notes

- 2026-08-10: Refined the performance plan after maintainer review. The hard release gate now
  explicitly protects the pre-existing `AckOk` workloads, while a separate current-tree
  benchmark records bounded code-validation and reason-rendering costs without making the
  uncommon dead-letter path obey the normal-throughput threshold. The implementation and
  documentation now require startup-time code validation, code reuse, rendering without a
  chained intermediate `Text`, and branch-local telemetry work.
- 2026-08-10: Recorded M1 completion and the compatibility decision that keeps the
  supervised renderer exhaustive between the pure-contract and telemetry milestones.
