---
id: 11
slug: add-headers-field-to-envelope
title: "Add headers field to Envelope"
kind: exec-plan
created_at: 2026-06-05T15:40:42Z
intention: "intention_01ktc72xhhem3a1ht30kpvvsgp"
---

# Add headers field to Envelope

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

After this change, every `Envelope` value passing through Shibuya can carry the
*complete* set of message headers that the source queue attached to a message, not
just the two W3C distributed-tracing headers. A "header" here is a raw key/value pair
that a message broker carries alongside the payload — for Kafka these are the entries
of a record's header block (for example `content-type: application/json`,
`correlation-id: 7f3a…`, a schema-registry id, or any custom application header). A
handler will be able to read `ingested.envelope.headers` and see every header verbatim,
in order, including duplicates.

Today this is impossible. The `Envelope` record
(`shibuya-core/src/Shibuya/Core/Types.hs`) has no general header field. The only
header-derived data it carries is `traceContext :: !(Maybe TraceHeaders)`, which by
design holds *only* the `traceparent` and (optionally) `tracestate` headers used to
re-establish a distributed trace. Every other header is dropped at the adapter boundary
because there is nowhere on the envelope to put it. Concretely, the Kafka adapter's
converter `Shibuya.Adapter.Kafka.Convert.consumerRecordToEnvelope` (in the separate
`shibuya-kafka-adapter` repository) reads a record's headers once, keeps only the trace
subset via `extractTraceHeaders`, and discards the rest. That data loss is silent: a
producer can set `content-type` and the consumer's handler has no way to ever see it.

This plan closes the gap *in `shibuya-core`* by giving the envelope a place to hold
headers. It adds:

1. A `Headers` type — an ordered list of raw key/value byte-string pairs.
2. A `headers :: !(Maybe Headers)` field on `Envelope`.

A reader can verify the change by:

1. Building the library with `cabal build shibuya-core` from the repo root and observing
   it succeeds.
2. Running `cabal test shibuya-core-test` and observing all tests pass — including a new
   assertion in `shibuya-core/test/Shibuya/Core/TypesSpec.hs` that the `headers` field
   round-trips through `fmap`.
3. Opening a REPL (`cabal repl shibuya-core`) and constructing an `Envelope` with a
   populated `headers` field (exact transcript in Validation and Acceptance), observing
   it typechecks and prints the headers back.

### Why a new field and not the existing `attributes` field

A natural objection is: `Envelope` already has an `attributes :: !(HashMap Text Attribute)`
field that adapters populate — why not route headers through it instead of adding a second
field? The answer is that `attributes` is the *wrong vehicle* on every axis that matters,
and the two concepts are orthogonal (one is observability *output*, the other is broker
*input* to the handler):

- **Purpose.** `attributes` is OpenTelemetry span enrichment, not handler-visible message
  data. `shibuya-core/src/Shibuya/Runner/Supervised.hs:397-398` unions it with the
  framework's `messaging.*` defaults and feeds the result straight into the per-message
  Consumer span via `addAttributes traceSpan mergedAttrs`. Its doc comment says so
  explicitly: "Adapter-supplied OpenTelemetry attributes for the per-message processing
  span." Dumping every broker header into it would pollute every span with arbitrary
  application headers and could even override the framework's semantic-convention defaults
  (e.g. an application header named `messaging.system`).
- **Order.** `attributes` is a `HashMap` — unordered. Kafka defines header order; a map
  cannot preserve it.
- **Duplicate keys.** A `HashMap` silently collapses duplicate keys. Kafka explicitly
  permits multiple headers with the same key; a map would drop all but one — the exact data
  loss this plan exists to stop.
- **Value fidelity.** `Attribute` values are typed primitives (`Text`, `Bool`, `Double`,
  `Int64`). A header value may be raw, non-UTF-8 bytes (e.g. a binary schema-registry id);
  it cannot be represented as an `Attribute` without lossy decoding. `headers` keeps both
  key and value as raw `ByteString`.
- **Key fidelity.** `attributes` keys are `Text` (UTF-8); header keys are bytes.

So `headers` and `attributes` are genuinely different fields with different directions of
data flow: `attributes` is what the adapter wants the *tracer* to record; `headers` is what
the *broker* delivered, preserved verbatim for the *handler*. Reusing `attributes` would be
both lossy and semantically wrong. This is the same reasoning that keeps `traceContext` a
separate parsed projection rather than something a handler digs out of a generic bag.

### What this plan does NOT do (scope boundary)

This plan does *not* populate the new field from any specific queue. In particular it
does not touch the Kafka adapter — that adapter lives in a different repository
(`shibuya-kafka-adapter`) and depends on `shibuya-core` as a library. Wiring
`consumerRecordToEnvelope` to fill `headers` from `crHeaders` is a *follow-up* that this
plan unblocks; it must happen in the adapter repo against the released core that contains
this field. This plan is the foundation: it gives adapters somewhere to put headers and
makes the data structurally representable. It is intentionally analogous to, and follows
the exact pattern of, the already-completed `docs/plans/5-add-attempt-to-envelope.md`,
which added the `attempt` field the same way.


## Progress

- [x] Milestone 1 (2026-06-05) — Added the `Headers` type alias and the
      `headers :: !(Maybe Headers)` field to `Envelope` in
      `shibuya-core/src/Shibuya/Core/Types.hs`. Updated the module export list, updated the
      hand-written `NFData` instance to force the new field, ran `nix fmt`. Verified:
      `cabal build lib:shibuya-core` succeeds.
- [x] Milestone 2 (2026-06-05) — Updated all thirteen in-tree `Envelope` construction sites
      (each passing `headers = Nothing`) and added two focused tests in
      `shibuya-core/test/Shibuya/Core/TypesSpec.hs`. Verified: `cabal build all` and
      `cabal test shibuya-core-test` pass (118 examples, 0 failures); both new assertions
      ("preserves headers through fmap", "defaults headers to Nothing in the test helper")
      appear and pass.
- [x] Milestone 3 (2026-06-05) — Re-exported `Headers` from the public hub
      `shibuya-core/src/Shibuya/Core.hs`, and added a `## Unreleased` section to
      `shibuya-core/CHANGELOG.md` documenting the breaking change and the planned `0.7.0.0`
      major bump. Verified in REPL: `import Shibuya.Core (Headers)` resolves and `e.headers`
      prints `Just [("content-type","application/json")]`.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Add a new dedicated `headers` field rather than routing broker headers through
  the existing `attributes :: !(HashMap Text Attribute)` field.
  Rationale: `attributes` is OpenTelemetry span enrichment — it is unioned with the
  framework's `messaging.*` defaults and pushed into the per-message Consumer span at
  `shibuya-core/src/Shibuya/Runner/Supervised.hs:397-398` (`addAttributes traceSpan
  mergedAttrs`). It is observability *output*, whereas headers are broker *input* destined
  for the handler — orthogonal concerns flowing in opposite directions. The `attributes`
  type is also structurally incapable of holding headers faithfully: a `HashMap` is
  unordered and drops duplicate keys (Kafka defines header order and permits repeated keys),
  and `Attribute` values are typed primitives (`Text`/`Bool`/`Double`/`Int64`) with `Text`
  keys, so a raw non-UTF-8 header value such as a binary schema id cannot be represented
  without lossy decoding. Reusing `attributes` would therefore be both lossy and
  semantically wrong, and would pollute tracing spans with arbitrary application headers.
  A separate `[(ByteString, ByteString)]` field preserves order, duplicates, and raw bytes.
  Date: 2026-06-05.

- Decision: Represent headers as `type Headers = [(ByteString, ByteString)]` — an ordered
  list of raw key/value byte pairs — rather than a `HashMap` or `Map`.
  Rationale: Broker headers are ordered and may contain duplicate keys (Kafka explicitly
  permits multiple headers with the same key). A map would silently drop duplicates and
  lose order, which contradicts the whole point of this change ("stop dropping headers").
  A list of pairs is also exactly the shape already used by `TraceHeaders` in this module,
  so the two header-derived fields stay consistent and an adapter can produce both from one
  source representation. Keys and values stay as raw `ByteString` because header values are
  not guaranteed to be UTF-8 text (e.g. a binary schema id); decoding is the handler's
  choice, not the framework's.
  Date: 2026-06-05.

- Decision: Wrap the field in `Maybe` (`headers :: !(Maybe Headers)`), matching
  `traceContext` and `attempt`.
  Rationale: `Nothing` means "this adapter does not surface headers at all," which is
  distinct from `Just []` meaning "this adapter surfaces headers and there were none on
  this message." That distinction is genuinely useful: it lets a handler tell a
  header-unaware source apart from a header-aware source that happened to receive a bare
  message. It also keeps the field shape uniform with the other two optional metadata
  fields on the envelope.
  Date: 2026-06-05.

- Decision: `headers` carries *all* headers verbatim, including `traceparent` and
  `tracestate`; `traceContext` stays as a separate, parsed projection of the trace subset.
  Rationale: The faithful, non-lossy thing is to expose the full header set as the broker
  delivered it. `traceContext` exists for a narrow, performance-sensitive purpose —
  `shibuya-core/src/Shibuya/Runner/Supervised.hs:374` reads it (`ingested.envelope.traceContext
  >>= extractTraceContext`) to re-establish the parent span — and changing or removing it
  would risk trace continuity. Keeping `headers` whole means an adapter does not have to
  decide which keys to strip, and a handler that wants the trace headers can still find them
  in `headers`. The mild redundancy (trace headers appearing in both fields) is acceptable
  and is documented on the field.
  Date: 2026-06-05.

- Decision: Place the new `headers` field immediately after `traceContext` in the record.
  Rationale: `traceContext` and `headers` are both header-derived; grouping them reads
  naturally ("the parsed trace subset, then the full set"). Source field order is otherwise
  invisible to callers because the package enables `OverloadedRecordDot` and disables
  positional field selectors (`NoFieldSelectors`), so the only practical effect is
  readability of the source and the diff. The hand-written `NFData` instance is updated in
  the same place to keep its forcing order matching the field order.
  Date: 2026-06-05.

- Decision: Do not bump the cabal `version:` field (currently `0.6.0.0`) in this plan; only
  record the planned `0.7.0.0` bump in `CHANGELOG.md` under `## Unreleased`.
  Rationale: This mirrors the completed `docs/plans/5-add-attempt-to-envelope.md`, which
  deferred the actual version bump to release time to avoid leaving the tree in a
  half-released state while related API work continues. Adding a record field breaks all
  direct `Envelope` constructions, so the eventual bump is a major one (`0.6.0.0` →
  `0.7.0.0`).
  Date: 2026-06-05.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Implemented 2026-06-05 in a single session. All three milestones landed as planned with no
deviations. The construction-site enumeration was exact (thirteen sites; the
`grep "Envelope$"` recipe located each), and `headers = Nothing` was the correct default at
every one. The `NFData` instance and CHANGELOG followed the `attempt`-field template
(`docs/plans/5`) verbatim. Final state: `cabal build all` clean, `cabal test
shibuya-core-test` 118 examples / 0 failures, `nix fmt` reports 0 changes, REPL confirms the
field round-trips and `Headers` is re-exported from `Shibuya.Core`. The pre-implementation
validation (headers vs. `attributes`) held up: nothing in the codebase made `attributes` a
viable home for raw headers. Out of scope and unblocked for follow-up: populating `headers`
from `consumerRecordToEnvelope` in the separate `shibuya-kafka-adapter` repo, and the actual
`0.7.0.0` version bump at release time.


## Context and Orientation

This repository (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) is the home of
the `shibuya-core` library. Everything under `shibuya-core/src/Shibuya/Core/` is a stable
identity-and-metadata layer: just types, no behavior. The modules relevant here:

- `shibuya-core/src/Shibuya/Core/Types.hs` defines `MessageId`, `Cursor`, `Attempt`,
  `TraceHeaders`, and `Envelope`. As of this writing `Envelope` has eight fields, in this
  order: `messageId`, `cursor`, `partition`, `enqueuedAt`, `traceContext`, `attempt`,
  `attributes`, `payload`. The module also contains a *hand-written* `NFData` instance for
  `Envelope` (not derived) — see below for why it must be edited.
- `shibuya-core/src/Shibuya/Core.hs` is the public re-export hub. Its export list has a
  `-- * Message Types` section that re-exports `MessageId (..)`, `Cursor (..)`,
  `Attempt (..)`, and `Envelope (..)`. Anything added to `Core/Types.hs` that should be
  user-visible through the umbrella module must be re-exported here. Note that `TraceHeaders`
  is *not* currently re-exported from this hub (it is exported from
  `Shibuya.Core.Types` and from `Shibuya.Telemetry.Propagation`); we will, however,
  re-export the new `Headers` alias because callers need it to name the field's type when
  constructing envelopes.
- `shibuya-core/src/Shibuya/Core/Ingested.hs` defines `Ingested es msg`, which wraps an
  `Envelope msg` with an ack handle and optional lease. Handlers receive `Ingested`, and
  reach the envelope via `ingested.envelope`.
- `shibuya-core/src/Shibuya/Runner/Supervised.hs` is the only place in the library that
  *reads* `traceContext` (line 374). It does not construct envelopes and is unaffected by
  adding a field, but it is named here so the reader understands the existing relationship
  between header data and tracing.

The repository builds with `cabal build all` from the repo root; the core test suite runs
with `cabal test shibuya-core-test`. There are three packages that *construct* `Envelope`
values and therefore must be updated when a field is added: the test suite
(`shibuya-core/test/...`), the example executable (`shibuya-example/app/Main.hs`), and the
benchmark package (`shibuya-core-bench/bench/...`). A repo-wide search for `Envelope {`
and a line beginning the record (`Envelope` followed by a brace block) found the thirteen
exact sites listed in the Plan of Work.

Terms of art used in this plan, defined in plain language:

- **Type alias.** `type Headers = [(ByteString, ByteString)]` introduces `Headers` as a new
  *name* for the existing list-of-pairs type. It is not a new distinct type; it is purely a
  readability aid, exactly like the existing `type TraceHeaders = [(ByteString, ByteString)]`
  in the same file.
- **`ByteString`.** A compact, immutable sequence of bytes from the `bytestring` package.
  Header keys and values are raw bytes here because broker header values are not guaranteed
  to be valid text.
- **`Maybe a`.** A value that is either `Nothing` (absent) or `Just x` (present, holding
  `x`). Used so a field can distinguish "not provided" from a provided-but-empty value.
- **`NFData` / `rnf`.** `NFData` is the type class from the `deepseq` package whose `rnf`
  method forces a value to *normal form* (fully evaluated, no thunks left). `Envelope`'s
  `NFData` instance is written by hand (rather than derived) because the `attributes` field
  holds `OpenTelemetry.Attributes.Attribute` values, which lack an upstream `NFData`
  instance; the hand-written instance forces every other field deeply and reduces
  `attributes` to weak-head normal form. Because it is hand-written, adding a field does not
  automatically force it — we must add a line for `headers`, or benchmarks that rely on full
  evaluation would silently leave the new field as an unforced thunk.
- **`OverloadedRecordDot` / `NoFieldSelectors`.** GHC extensions enabled by default in this
  package (see `default-extensions` in `shibuya-core/shibuya-core.cabal`).
  `OverloadedRecordDot` lets you write `env.headers` instead of `headers env`.
  `NoFieldSelectors` means top-level field-accessor functions are *not* generated, so fields
  are read via record-dot syntax, `generic-lens` `#field` labels, or pattern matching —
  never as a bare function call like `headers env`.

This plan is the direct analogue of the completed `docs/plans/5-add-attempt-to-envelope.md`
(adding the `attempt` field). That plan is checked into this repository; reading it is
optional but it is the proven template this plan follows.


## Plan of Work

The work is three milestones: define the type and field; fix every construction site and add
tests; re-export and document. Each milestone leaves the tree in a known, verifiable state.


### Milestone 1: Define `Headers` and add the field

Open `shibuya-core/src/Shibuya/Core/Types.hs`.

First, extend the module export list. It currently reads:

    module Shibuya.Core.Types
      ( -- * Message Identity
        MessageId (..),

        -- * Cursor / Offset
        Cursor (..),

        -- * Delivery Attempt
        Attempt (..),

        -- * Message Envelope
        Envelope (..),

        -- * Trace Context
        TraceHeaders,
      )
    where

Add a `Headers` export. Put it in its own section just before the Trace Context section:

        -- * Message Envelope
        Envelope (..),

        -- * Message Headers
        Headers,

        -- * Trace Context
        TraceHeaders,
      )
    where

Second, define the `Headers` alias next to the existing `TraceHeaders` alias. The existing
declaration is:

    -- | W3C Trace Context headers for distributed tracing.
    -- Contains traceparent and optionally tracestate headers.
    type TraceHeaders = [(ByteString, ByteString)]

Add immediately above it:

    -- | Raw message headers as delivered by the source broker.
    --
    -- An ordered list of @(key, value)@ byte-string pairs. Order is
    -- preserved and duplicate keys are allowed, because brokers such as
    -- Kafka permit multiple headers with the same key and define header
    -- order. Keys and values are raw 'ByteString' because header values
    -- are not guaranteed to be UTF-8 text (for example a binary schema
    -- id); decoding is left to the handler.
    type Headers = [(ByteString, ByteString)]

Third, add the field to the `Envelope` record. The current record is:

    data Envelope msg = Envelope
      { -- | Unique message identifier
        messageId :: !MessageId,
        -- | Optional position/offset
        cursor :: !(Maybe Cursor),
        -- | Optional partition key (for Kafka-style queues)
        partition :: !(Maybe Text),
        -- | When the message was enqueued
        enqueuedAt :: !(Maybe UTCTime),
        -- | W3C trace context headers for distributed tracing
        traceContext :: !(Maybe TraceHeaders),
        -- | Optional zero-indexed delivery counter. ...
        attempt :: !(Maybe Attempt),
        -- | Adapter-supplied OpenTelemetry attributes ...
        attributes :: !(HashMap Text Attribute),
        -- | The actual message payload
        payload :: !msg
      }

Insert `headers` immediately after `traceContext` and before `attempt`:

        -- | W3C trace context headers for distributed tracing
        traceContext :: !(Maybe TraceHeaders),
        -- | All message headers as delivered by the source broker, in
        -- order and including duplicates.
        --
        -- 'Nothing' means the adapter does not surface headers at all;
        -- 'Just []' means the adapter surfaces headers and this message
        -- carried none. The W3C trace headers ('traceparent' /
        -- 'tracestate') appear here verbatim *in addition to* their
        -- parsed form in 'traceContext'; this field is the faithful,
        -- non-lossy view and 'traceContext' is the narrow projection the
        -- framework uses to re-establish a parent span.
        headers :: !(Maybe Headers),
        -- | Optional zero-indexed delivery counter. ...
        attempt :: !(Maybe Attempt),

(The `...` above is shorthand for the existing comment text — leave that text unchanged.)

Fourth, update the hand-written `NFData` instance so the new field is forced. The current
instance is:

    instance (NFData msg) => NFData (Envelope msg) where
      rnf e =
        rnf e.messageId `seq`
          rnf e.cursor `seq`
            rnf e.partition `seq`
              rnf e.enqueuedAt `seq`
                rnf e.traceContext `seq`
                  rnf e.attempt `seq`
                    e.attributes `seq`
                      rnf e.payload

Add an `rnf e.headers` step right after `traceContext`, matching the field order:

    instance (NFData msg) => NFData (Envelope msg) where
      rnf e =
        rnf e.messageId `seq`
          rnf e.cursor `seq`
            rnf e.partition `seq`
              rnf e.enqueuedAt `seq`
                rnf e.traceContext `seq`
                  rnf e.headers `seq`
                    rnf e.attempt `seq`
                      e.attributes `seq`
                        rnf e.payload

`Headers` is `[(ByteString, ByteString)]`, and both list and `ByteString` already have
`NFData` instances, so `rnf e.headers` compiles with no new imports or instances.

Run `nix fmt` from the repo root to normalize whitespace/indentation (treefmt will adjust
the `seq` ladder layout).

Build just the library target:

    cabal build shibuya-core

This must succeed. The test, example, and benchmark targets will *not* build yet because
their `Envelope` constructions are now missing the field — that is expected and is the
subject of Milestone 2. The library compiles because nothing inside
`shibuya-core/src/` constructs an `Envelope` literal (the library only pattern-matches on
and reads envelopes).

Acceptance for M1: `cabal build shibuya-core` is clean (no `-Wall` warnings mentioning
`Envelope` or `headers`).


### Milestone 2: Update every construction site and add tests

Adding a field to a record breaks every place that builds the record with explicit fields.
A repo-wide search located thirteen such sites across three packages. Update each one by
adding `headers = Nothing,` (placed next to the existing `traceContext = Nothing,` line for
readability — exact position does not matter to the compiler). `Nothing` is correct at every
site because these are mock/test/example/benchmark messages with no real broker headers.

The thirteen sites:

1. `shibuya-example/app/Main.hs` — the `Envelope` literal at approximately line 78 (in the
   helper that builds a mock ingested message).
2. `shibuya-core/test/Shibuya/RunnerSpec.hs` — two literals, at approximately lines 203 and
   228.
3. `shibuya-core/test/Shibuya/Core/RetrySpec.hs` — one literal at approximately line 19.
4. `shibuya-core/test/Shibuya/Core/TypesSpec.hs` — the `testEnvelope` helper literal at
   approximately line 85.
5. `shibuya-core/test/Shibuya/Runner/SupervisedSpec.hs` — two literals, at approximately
   lines 851 and 875.
6. `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs` — two literals, at approximately
   lines 61 and 115.
7. `shibuya-core-bench/bench/Bench/Handler.hs` — one literal at approximately line 128.
8. `shibuya-core-bench/bench/Bench/Framework.hs` — one literal at approximately line 151.
9. `shibuya-core-bench/bench/Bench/Concurrency.hs` — one literal at approximately line 224.
10. `shibuya-core-bench/bench/Test/StandaloneTest.hs` — one literal at approximately line
    112.

Line numbers are approximate; the build will name any site you miss with a precise
`file:line` "missing field `headers`" error, so the recovery loop is: build, read the error,
add the field, repeat. To re-locate the sites at any time, run from the repo root:

    grep -rn "Envelope$" --include='*.hs' shibuya-core shibuya-core-bench shibuya-example | grep -v "data Envelope"

Each match is the first line of a record literal; the `headers` field goes inside its brace
block.

After updating the sites, add tests to `shibuya-core/test/Shibuya/Core/TypesSpec.hs`. Inside
the existing `describe "Envelope"` block, add an assertion that the field round-trips through
`fmap` (the `Functor` instance maps over `payload` only and must leave metadata, including
`headers`, untouched):

    it "preserves headers through fmap" $ do
      let env = (testEnvelope (1 :: Int)) {headers = Just [("content-type", "application/json")]}
          mapped = fmap show env
      mapped.headers `shouldBe` Just [("content-type", "application/json")]

Also assert the default constructed by the helper is `Nothing`, so a regression that
accidentally changes the helper's default is caught:

    it "defaults headers to Nothing in the test helper" $ do
      (testEnvelope (1 :: Int)).headers `shouldBe` Nothing

These tests use record-update and record-dot syntax because `NoFieldSelectors` is enabled
(no bare `headers env` accessor exists). The `testEnvelope` helper is the one you updated in
site 4 above; it already constructs a complete envelope, so the update adds
`headers = Nothing,` to it and these tests then override or read that default.

Build the whole workspace and run the core tests from the repo root:

    cabal build all
    cabal test shibuya-core-test

Both must succeed. `shibuya-example` and `shibuya-core-bench` have no test suites of their
own; `cabal build all` covers their compilation.

Acceptance for M2: `cabal build all` succeeds; `cabal test shibuya-core-test` passes; the
two new assertions ("preserves headers through fmap" and "defaults headers to Nothing in the
test helper") appear in the test output and pass.


### Milestone 3: Re-export and document

Open `shibuya-core/src/Shibuya/Core.hs`. The export list has a `-- * Message Types` section:

      ( -- * Message Types
        MessageId (..),
        Cursor (..),
        Attempt (..),
        Envelope (..),

Add `Headers` to it:

      ( -- * Message Types
        MessageId (..),
        Cursor (..),
        Attempt (..),
        Envelope (..),
        Headers,

Then update the corresponding import near the top of the same file. It currently reads:

    import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), MessageId (..))

Change it to also import `Headers`:

    import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), Headers, MessageId (..))

(`Headers` is a type alias, so it is imported by its bare name with no `(..)`.)

Open `shibuya-core/CHANGELOG.md`. The newest section is `## 0.6.0.0 — 2026-05-31`. Add a new
`## Unreleased` section *above* it (between the `# Changelog` title and the `0.6.0.0`
section):

    ## Unreleased

    ### Breaking Changes

    - `Envelope` gained a `headers :: !(Maybe Headers)` field carrying every
      message header the source broker delivered, in order and including
      duplicates. Direct constructions of `Envelope` must add the field.
      `Nothing` means the adapter does not surface headers; `Just []` means
      it does and the message had none. The new `Headers` type alias
      (`[(ByteString, ByteString)]`) is exported from `Shibuya.Core` and
      `Shibuya.Core.Types`. The W3C trace headers continue to appear in
      `traceContext` as before; they now also appear verbatim in `headers`.

    Planned next release: 0.7.0.0 (major — breaks direct `Envelope` construction).

Do *not* change the `version:` field in `shibuya-core/shibuya-core.cabal` (it stays at
`0.6.0.0`). Per the Decision Log, the actual bump happens at release time to avoid a
half-released tree.

Run from the repo root:

    nix fmt
    cabal build all
    cabal test shibuya-core-test

All must succeed.

Acceptance for M3: `Shibuya.Core` exports `Headers` (verifiable in a REPL with
`import Shibuya.Core (Headers)`); `Shibuya.Core.Types` exports `Headers`; `CHANGELOG.md`
mentions both the new field and the planned `0.7.0.0` release.


## Concrete Steps

All commands run from the repo root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`.

Per-milestone build/test loop:

    # Milestone 1
    cabal build shibuya-core

    # Milestone 2
    cabal build all
    cabal test shibuya-core-test

    # Milestone 3
    nix fmt
    cabal build all
    cabal test shibuya-core-test

After all three milestones, the canonical end-to-end verification sequence is:

    cabal clean
    nix fmt
    cabal build all
    cabal test shibuya-core-test --test-show-details=direct

Expected tail of the test output:

    Finished in 0.0X seconds
    NN examples, 0 failures

where `NN` is the prior example count plus the two new assertions added in Milestone 2.

Commit after each milestone. Every commit must carry both trailers (an Intention is active
for this work):

    ExecPlan: docs/plans/11-add-headers-field-to-envelope.md
    Intention: intention_01ktc72xhhem3a1ht30kpvvsgp

Follow Conventional Commits, e.g. `feat(core)!: add headers field to Envelope` (the `!`
marks the breaking change).


## Validation and Acceptance

A reader who has only this plan and the working tree can verify the change by:

1. Running `cabal build all` and observing it succeeds with no `-Wall` warnings related to
   `Envelope` or `headers`.

2. Running `cabal test shibuya-core-test` and confirming the two new assertions appear and
   pass:

       Envelope
         preserves headers through fmap
         defaults headers to Nothing in the test helper

3. Opening a REPL with `cabal repl shibuya-core` and entering:

       :set -XOverloadedStrings
       import Shibuya.Core.Types
       let e = Envelope (MessageId "x") Nothing Nothing Nothing Nothing (Just [("content-type", "application/json")]) Nothing mempty "hello"
       e.headers

   Expected output:

       Just [("content-type","application/json")]

   (The positional constructor arguments are, in order: `messageId`, `cursor`, `partition`,
   `enqueuedAt`, `traceContext`, `headers`, `attempt`, `attributes`, `payload`. The
   `mempty` supplies the empty `attributes` HashMap.)

4. Confirming `import Shibuya.Core (Headers)` resolves in the REPL, proving the re-export:

       import Shibuya.Core (Headers, Envelope(..))

   resolves with no "not in scope" error.

The plan is "done" when all three milestones' acceptance criteria are met and the canonical
verification sequence in Concrete Steps passes cleanly.


## Idempotence and Recovery

Every step here is idempotent — re-running `nix fmt`, `cabal build`, or `cabal test` is
safe and has no side effects beyond the build cache. No schema, database, or external state
is touched.

If a milestone's edits land partially (for example, the field is added but a construction
site is missed), `cabal build all` reports the missing field with a precise `file:line`
("missing field in record construction `headers`"). Add the field at that site and re-build;
repeat until clean. The grep in Milestone 2 re-locates all construction sites at any time.

To roll back entirely: `git restore` the affected files
(`shibuya-core/src/Shibuya/Core/Types.hs`, `shibuya-core/src/Shibuya/Core.hs`,
`shibuya-core/CHANGELOG.md`, and the thirteen construction-site files). No further cleanup is
needed.


## Interfaces and Dependencies

This plan introduces no new external dependencies. `ByteString` is already imported in
`Shibuya.Core.Types` (used by `TraceHeaders`); `NFData` for lists and `ByteString` is already
available via `deepseq` and `bytestring`.

At the end of this plan the following are visible to downstream users.

In `shibuya-core/src/Shibuya/Core/Types.hs`:

    type Headers = [(ByteString, ByteString)]

    data Envelope msg = Envelope
      { messageId    :: !MessageId
      , cursor       :: !(Maybe Cursor)
      , partition    :: !(Maybe Text)
      , enqueuedAt   :: !(Maybe UTCTime)
      , traceContext :: !(Maybe TraceHeaders)
      , headers      :: !(Maybe Headers)
      , attempt      :: !(Maybe Attempt)
      , attributes   :: !(HashMap Text Attribute)
      , payload      :: !msg
      }

Re-exported from `Shibuya.Core` so that `import Shibuya.Core (Headers, Envelope(..))` works.

### Downstream follow-up (out of scope for this plan)

Once this plan lands and a core version containing `headers` is available, the Kafka adapter
in the separate `shibuya-kafka-adapter` repository should be updated to populate it. Today
`Shibuya.Adapter.Kafka.Convert.consumerRecordToEnvelope` sets only `traceContext` (via
`extractTraceHeaders`) and drops the rest of `cr.crHeaders`. The follow-up sets
`headers = Just (headersToList cr.crHeaders)` (using `Kafka.Types.headersToList`) so the full
header set is preserved end to end. That work belongs to the adapter repo and is tracked
there; this plan only makes it possible by giving the envelope a field to hold the data.


## Revision History

- 2026-06-05 — Validated the core API choice (headers vs. attributes) at the user's request.
  Confirmed against the codebase that the existing `attributes` field is unsuitable for
  broker headers: it is an OpenTelemetry span input
  (`shibuya-core/src/Shibuya/Runner/Supervised.hs:397-398` feeds it to `addAttributes`),
  is a `HashMap` (loses order and duplicate keys), and uses typed `Attribute` values with
  `Text` keys (cannot hold raw non-UTF-8 header bytes). Added a "Why a new field and not the
  existing `attributes` field" subsection under Purpose and a corresponding Decision Log
  entry. No change to the milestones, construction-site list, or acceptance criteria — the
  validation confirms the plan as written; the dedicated `headers` field is the correct API.
