---
id: 13
slug: upgrade-shibuya-kafka-adapter-for-envelope-headers-field
title: "Upgrade shibuya-kafka-adapter for Envelope headers field"
kind: exec-plan
created_at: 2026-06-05T16:02:08Z
intention: "intention_01ktc7yzxhex7r1wgt15apscaz"
master_plan: "docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md"
---

# Upgrade shibuya-kafka-adapter for Envelope headers field

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shibuya-core` `0.7.0.0` added a new field to its central `Envelope` record:
`headers :: !(Maybe Headers)`, where `type Headers = [(ByteString, ByteString)]`. This
field is meant to carry every raw message header the source broker delivered, in order and
including duplicate keys, as raw bytes. Adding this field is a breaking change: every place
that constructs an `Envelope` with record syntax now fails to type-check until it supplies
the field.

The `shibuya-kafka-adapter` package turns Apache Kafka topic records into Shibuya
`Envelope`s. Kafka is one of the few brokers that *does* deliver real per-message headers
(an ordered list of `(key, value)` byte pairs, with duplicate keys permitted), so this
adapter is the one place in the whole initiative where the new `headers` field can be
populated with genuine data rather than `Nothing`. After this change, a handler running on
top of the Kafka adapter can read `envelope.headers` and see exactly the headers Kafka
delivered — for example a `schema-id` header or a custom routing header — which was
previously impossible (only the parsed W3C trace headers were surfaced, via
`traceContext`).

You can see it working by running the adapter's test suite: a new test constructs a Kafka
`ConsumerRecord` carrying headers and asserts that `consumerRecordToEnvelope` copies them
verbatim into `envelope.headers`.

This plan lives in the `shibuya` repository's `docs/plans/` directory, but the code it
changes is in a **separate git repository**:
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. All edits, builds,
tests, commits, and tags in this plan happen in *that* repository. The commit trailers
(`MasterPlan:`/`ExecPlan:`) reference the plan paths as they exist in the `shibuya` repo.

This plan **hard-depends** on
`docs/plans/12-release-shibuya-core-and-shibuya-metrics-0-7-0-0-and-standardize-cabal-version-3-12.md`:
the adapter sources `shibuya-core` from Hackage, and the new `headers` field does not exist
in any published `shibuya-core` before `0.7.0.0`. You cannot even compile the change until
a `shibuya-core` `0.7.0.0` is available to the adapter (from Hackage, or temporarily
git-pinned — see Idempotence and Recovery).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Verified `shibuya-core 0.7.0.0` via a temporary local-source pin in `cabal.project` (removed before commit). (2026-06-05)
- [x] M1: Bumped `shibuya-core ^>=0.6.0.0` → `^>=0.7.0.0` in all four occurrences (3 cabal files, incl. test suite). (2026-06-05)
- [x] M1: Added `headers = Just (headersToList cr.crHeaders)` to `consumerRecordToEnvelope` (+ haddock). (2026-06-05)
- [x] M1: `cabal build shibuya-kafka-adapter` succeeds against local `shibuya-core 0.7.0.0` (inside `nix develop`). (2026-06-05)
- [x] M2: Added unit tests asserting verbatim/duplicate-preserving headers and the `Just []` empty case. (2026-06-05)
- [x] M2: `cabal test shibuya-kafka-adapter` green — 28 tests passed (was 26). (2026-06-05)
- [x] M3: Bumped the three packages' `version:` to `0.7.0.0`; added CHANGELOG entry; removed the temp pin; `nix fmt` clean. (2026-06-05)
- [x] M3: Committed `424a4c2` and tagged `v0.7.0.0` in the kafka repo. (2026-06-05)
- [ ] M3 (privileged, owned by user): publish `shibuya-kafka-adapter 0.7.0.0` to Hackage (after `shibuya-core 0.7.0.0` is published).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Populate `headers` with `Just (headersToList cr.crHeaders)` — i.e. surface
  *all* Kafka headers verbatim, not `Nothing`.
  Rationale: Kafka genuinely delivers ordered, duplicate-allowing headers and they are
  already in hand at the single construction site (the existing `traceContext` extraction
  already calls `headersToList cr.crHeaders`). Surfacing them is the whole point of the new
  field, and `Just []` naturally results when a record carried no headers, which is the
  correct "headers supported, none present" signal. Using `Nothing` would throw away
  available data and misreport the adapter as not supporting headers.
  Date: 2026-06-05

- Decision: Bump the adapter (and its sibling `-jitsurei` and `-bench` packages) to
  `0.7.0.0`.
  Rationale: The adapter's public surface changes in lockstep with the `shibuya-core`
  breaking release it now requires; the repo's prior releases tracked the core version
  (e.g. its `0.6.0.0` "tracks shibuya-core 0.6.0.0"). Matching `0.7.0.0` keeps the
  ecosystem versions aligned.
  Date: 2026-06-05

- Decision: No `cabal-version` change in this repository.
  Rationale: All three `.cabal` files already declare `cabal-version: 3.12`; the Nix
  compatibility concern that motivates lowering `3.14` does not apply here.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

As of 2026-06-05 the adapter is upgraded and released locally (commit `424a4c2`, tag
`v0.7.0.0`). `consumerRecordToEnvelope` now surfaces every Kafka header verbatim;
`cabal test shibuya-kafka-adapter` reports 28 tests passing, including the new cases that
prove order and duplicate keys round-trip into `env.headers` and that an empty record
yields `Just []`. `hw-kafka-client`'s `Headers` turned out to be a plain newtype over
`[(ByteString, ByteString)]` (`headersFromList = Headers`, `headersToList = unHeaders`), so
order/duplicate preservation is exact and the assertions are unambiguous.

Build verification used a temporary local-source pin (`packages: ../shibuya/shibuya-core`)
in `cabal.project` because `shibuya-core 0.7.0.0` was not yet on Hackage and the
`v0.7.0.0` tag was unpushed; the pin was removed before committing, so the released adapter
depends solely on Hackage `shibuya-core ^>=0.7.0.0`. The only remaining step is the
privileged Hackage upload of the adapter, which must follow the `shibuya-core 0.7.0.0`
publish and is owned by the user.


## Context and Orientation

The repository to edit is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`. Treat every path
below as relative to that directory unless shown absolute. It is a Cabal multi-package
project whose `cabal.project` declares three packages:

```text
packages:
  shibuya-kafka-adapter
  shibuya-kafka-adapter-jitsurei
  shibuya-kafka-adapter-bench
```

The `cabal.project` sources `shibuya-core` from Hackage (it is *not* pinned via
`source-repository-package`; only the `hs-opentelemetry` package set is pinned from
GitHub). Its full content is:

```text
packages:
  shibuya-kafka-adapter
  shibuya-kafka-adapter-jitsurei
  shibuya-kafka-adapter-bench

-- hs-opentelemetry 1.0 package set from GitHub (for GHC 9.12 support)
source-repository-package
  type: git
  location: https://github.com/iand675/hs-opentelemetry
  tag: hs-opentelemetry-api-types-1.0.0.0
  subdir:
    api
    api-types
    sdk
    otlp
    propagators/w3c
    semantic-conventions
    instrumentation/hw-kafka-client
    exporters/otlp

-- Allow newer for GHC 9.12 boot library compatibility
allow-newer:
  proto-lens:base,
  proto-lens:ghc-prim,
  proto-lens-runtime:base,
  proto-lens-protobuf-types:base,
  proto-lens-protobuf-types:ghc-prim
```

The three `.cabal` files and their current state:

- `shibuya-kafka-adapter/shibuya-kafka-adapter.cabal`: `cabal-version: 3.12`,
  `version: 0.6.0.0`, dependency `shibuya-core ^>=0.6.0.0` (around line 64); the test
  suite also depends on `shibuya-core`.
- `shibuya-kafka-adapter-jitsurei/shibuya-kafka-adapter-jitsurei.cabal`:
  `cabal-version: 3.12`, `version: 0.6.0.0`, `shibuya-core ^>=0.6.0.0` (around line 44).
- `shibuya-kafka-adapter-bench/shibuya-kafka-adapter-bench.cabal`: `cabal-version: 3.12`,
  `version: 0.6.0.0`, `shibuya-core ^>=0.6.0.0` (around line 59).

The **single** place that constructs an `Envelope` is the function
`consumerRecordToEnvelope` in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` (lines 57–66 at the time of
research):

```haskell
consumerRecordToEnvelope ::
    ConsumerRecord (Maybe ByteString) (Maybe ByteString) ->
    Envelope (Maybe ByteString)
consumerRecordToEnvelope cr =
    Envelope
        { messageId = mkMessageId cr.crTopic cr.crPartition cr.crOffset
        , cursor = Just (CursorInt (fromIntegral (unOffset cr.crOffset)))
        , partition = Just (Text.pack (show (unPartitionId cr.crPartition)))
        , enqueuedAt = timestampToUTCTime cr.crTimestamp
        , traceContext = extractTraceHeaders cr.crHeaders
        , attempt = Nothing
        , attributes = kafkaSpanAttributes cr.crPartition cr.crOffset
        , payload = cr.crValue
        }
```

Here `cr :: ConsumerRecord (Maybe ByteString) (Maybe ByteString)` comes from the
`hw-kafka-client` library. `cr.crHeaders :: Headers` is Kafka's header collection (the
`Headers` type from `hw-kafka-client`'s `Kafka.Types`, *not* the `shibuya-core`
`Headers` alias — be careful, the names collide). The module already imports the helper
`headersToList :: Kafka.Types.Headers -> [(ByteString, ByteString)]` (from `Kafka.Types`)
and uses it inside `extractTraceHeaders`. That `[(ByteString, ByteString)]` result is
exactly the shape of `shibuya-core`'s `Headers` alias, so it can be dropped straight into
the new field.

The existing trace-context extraction in the same file (lines 96–109) is the pattern to
mirror:

```haskell
extractTraceHeaders :: Headers -> Maybe TraceHeaders
extractTraceHeaders headers =
    case (lookup "traceparent" headerList, lookup "tracestate" headerList) of
        (Nothing, _) -> Nothing
        (Just tp, Nothing) -> Just [("traceparent", tp)]
        (Just tp, Just ts) -> Just [("traceparent", tp), ("tracestate", ts)]
  where
    headerList :: [(ByteString, ByteString)]
    headerList = headersToList headers
```

Note that `extractTraceHeaders` keeps the narrow, parsed projection of trace headers; the
new `headers` field is the *faithful, complete* view. Both will be populated — this matches
the `shibuya-core` documentation, which says the W3C trace headers "continue to appear in
`traceContext`; they now also appear verbatim in `headers`."

Tests live under `shibuya-kafka-adapter/test/`. The relevant unit-test module is
`test/Shibuya/Adapter/Kafka/ConvertTest.hs`. It already has a helper
`mkRecord` that builds a `ConsumerRecord` from headers (built with `headersFromList ::
[(ByteString, ByteString)] -> Headers` from `Kafka.Types`) plus an existing test
"traceContext extracted from headers" that you can copy as a template:

```haskell
, testCase "traceContext extracted from headers" $ do
    let hdrs = headersFromList [("traceparent", "00-abc-def-01")]
        cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 0) NoTimestamp hdrs Nothing Nothing
        env = consumerRecordToEnvelope cr
    assertEqual "traceContext" (Just [("traceparent", "00-abc-def-01")]) env.traceContext
```

Build/test/format commands for this repository (a `Justfile` and a `flake.nix` are
present; the dev shell provides GHC 9.12.4, cabal, HLS, rdkafka, `just`, and
`process-compose`):

```bash
cabal build all
cabal test shibuya-kafka-adapter     # unit tests; integration tests need Redpanda
just process-up                      # start Redpanda for the 5 integration tests
nix fmt                              # format before committing
nix flake check
```

Term definitions: a **ConsumerRecord** is `hw-kafka-client`'s representation of one polled
Kafka message (topic, partition, offset, timestamp, headers, key, value). **Redpanda** is
a Kafka-API-compatible broker the integration tests run against; the pure unit tests
(including the one this plan adds) do not need it. **`-jitsurei`** is the repository's
example/demonstration executable; **`-bench`** is its benchmark package.

Release convention: git tags are `v`-prefixed (e.g. `v0.6.0.0`); `shibuya-kafka-adapter`
is published to Hackage via `cabal sdist` + `cabal upload --publish`.


## Plan of Work

Three milestones: M1 makes the adapter compile against `shibuya-core 0.7.0.0` with the new
field populated; M2 proves the data round-trips with a test; M3 versions, documents, and
releases.

### Milestone 1 — Bump the dependency and populate the field

Scope: the adapter builds against `shibuya-core 0.7.0.0`, and every Kafka record's headers
flow into `envelope.headers`. At the end `cabal build all` succeeds.

First ensure a `shibuya-core 0.7.0.0` is actually resolvable. If
`docs/plans/12-...` has already published `0.7.0.0` to Hackage, nothing else is needed. If
publishing has not happened yet but you want to proceed in parallel, temporarily pin the
core from git by adding to this repo's `cabal.project` (remove before release — see
Idempotence and Recovery):

```text
source-repository-package
  type: git
  location: https://github.com/<the shibuya repo remote>
  tag: v0.7.0.0
  subdir:
    shibuya-core
    shibuya-metrics
```

Then bump the constraint from `^>=0.6.0.0` to `^>=0.7.0.0` in all three `.cabal` files
(library dependency and the test-suite dependency in
`shibuya-kafka-adapter.cabal`, plus the `-jitsurei` and `-bench` cabal files). Confirm
with `grep -rn "shibuya-core" --include="*.cabal" .`.

Edit `consumerRecordToEnvelope` in
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` to add the `headers` field.
Place it next to `traceContext` so the relationship is obvious:

```haskell
consumerRecordToEnvelope cr =
    Envelope
        { messageId = mkMessageId cr.crTopic cr.crPartition cr.crOffset
        , cursor = Just (CursorInt (fromIntegral (unOffset cr.crOffset)))
        , partition = Just (Text.pack (show (unPartitionId cr.crPartition)))
        , enqueuedAt = timestampToUTCTime cr.crTimestamp
        , traceContext = extractTraceHeaders cr.crHeaders
        , headers = Just (headersToList cr.crHeaders)
        , attempt = Nothing
        , attributes = kafkaSpanAttributes cr.crPartition cr.crOffset
        , payload = cr.crValue
        }
```

`headersToList` is already imported in this module. When a record carries no headers,
`headersToList cr.crHeaders` is `[]`, so the field becomes `Just []` — the correct
"adapter surfaces headers; this message had none" signal. There is no scenario in which
this adapter should report `Nothing` for `headers`, because it always has Kafka's header
list available.

Acceptance: `cabal build all` succeeds with `shibuya-core 0.7.0.0` resolved.

### Milestone 2 — Test that headers round-trip

Scope: a unit test proves real Kafka headers reach `envelope.headers` verbatim, including
order and a duplicate key. At the end `cabal test shibuya-kafka-adapter` passes its unit
tests.

In `test/Shibuya/Adapter/Kafka/ConvertTest.hs`, add a test modeled on the existing
"traceContext extracted from headers" case. Build a record with a couple of non-trace
headers plus a duplicate key to demonstrate order and duplicate preservation, and assert
on `env.headers`:

```haskell
, testCase "headers surfaced verbatim from the consumer record" $ do
    let raw = [("schema-id", "42"), ("x-tag", "a"), ("x-tag", "b")]
        cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 0) NoTimestamp
               (headersFromList raw) Nothing Nothing
        env = consumerRecordToEnvelope cr
    assertEqual "headers" (Just raw) env.headers
, testCase "empty headers surface as Just []" $ do
    let cr = mkRecord (TopicName "t") (PartitionId 0) (Offset 0) NoTimestamp
               (headersFromList []) Nothing Nothing
        env = consumerRecordToEnvelope cr
    assertEqual "headers" (Just []) env.headers
```

If `headersFromList` does not preserve a duplicate key or its order (verify against the
`hw-kafka-client` `Kafka.Types` source if the assertion fails), weaken the first
assertion to the order/keys it does preserve and record that in Surprises & Discoveries —
the essential acceptance is that non-trace headers reach `env.headers`, and that empty
headers yield `Just []` rather than `Nothing`.

Acceptance: `cabal test shibuya-kafka-adapter` runs the unit suite green (the five
Redpanda integration tests need `just process-up`; they are unaffected by this change but
may be run for completeness).

### Milestone 3 — Version, changelog, tag, publish

Scope: bump the three packages to `0.7.0.0`, document the change, format, commit, tag, and
(gated) publish. At the end the adapter release exists in git and, once authorized, on
Hackage.

Edits: set `version: 0.7.0.0` in all three `.cabal` files. Prepend a CHANGELOG entry to
`shibuya-kafka-adapter/CHANGELOG.md`:

```markdown
## 0.7.0.0 — 2026-06-05

### Changed

- Require `shibuya-core ^>=0.7.0.0`. `Envelope` now carries a
  `headers :: Maybe Headers` field; `consumerRecordToEnvelope` populates it
  with every Kafka header verbatim (ordered, duplicates preserved) via
  `headersToList`. A record with no headers yields `Just []`. The parsed W3C
  trace headers continue to appear in `traceContext` and now also appear
  verbatim in `headers`.
```

Then format, commit, tag, and (privileged) publish per Concrete Steps.

Acceptance: `git tag` shows `v0.7.0.0`; the sdist's `.cabal` reports `version: 0.7.0.0`;
after authorized upload, `https://hackage.haskell.org/package/shibuya-kafka-adapter-0.7.0.0`
resolves.


## Concrete Steps

Run everything from
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter` inside its
`nix develop` shell.

```bash
# M1: bump constraint in all three cabal files, then:
grep -rn "shibuya-core" --include="*.cabal" .   # expect ^>=0.7.0.0 everywhere it is bounded
cabal build all

# M2: after adding tests
cabal test shibuya-kafka-adapter

# M3: after bumping versions + changelog
nix fmt
git add -A
git commit -m "feat!: surface Kafka headers on Envelope and require shibuya-core 0.7

consumerRecordToEnvelope now sets the new Envelope.headers field with the
full, verbatim Kafka header list. Bump shibuya-core constraint to ^>=0.7.0.0
and the package versions to 0.7.0.0.

MasterPlan: docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md
ExecPlan: docs/plans/13-upgrade-shibuya-kafka-adapter-for-envelope-headers-field.md
Intention: intention_01ktc7yzxhex7r1wgt15apscaz"

git tag -a v0.7.0.0 -m "shibuya-kafka-adapter 0.7.0.0"
cabal sdist shibuya-kafka-adapter
tar -xzf dist-newstyle/sdist/shibuya-kafka-adapter-0.7.0.0.tar.gz -O \
  shibuya-kafka-adapter-0.7.0.0/shibuya-kafka-adapter.cabal | head -5
```

Privileged publish — only after explicit user authorization, because Hackage uploads are
irreversible:

```bash
cabal upload --publish dist-newstyle/sdist/shibuya-kafka-adapter-0.7.0.0.tar.gz
```


## Validation and Acceptance

1. `cabal build all` succeeds with `shibuya-core 0.7.0.0` resolved
   (`cabal build all -v0 && echo OK`).
2. `cabal test shibuya-kafka-adapter` runs green for the unit suite; the new tests assert
   `env.headers == Just [("schema-id","42"),("x-tag","a"),("x-tag","b")]` (or the
   order/keys `headersFromList` preserves) and `env.headers == Just []` for an empty
   record. This is the behavioral proof that real headers reach the envelope — something
   no published version could do before.
3. `grep -rn "shibuya-core" --include="*.cabal" .` shows `^>=0.7.0.0` on every bounded
   occurrence; the three `version:` fields read `0.7.0.0`.
4. The git tag `v0.7.0.0` exists and the sdist `.cabal` reports `version: 0.7.0.0`.
5. After authorized upload, the Hackage page for `shibuya-kafka-adapter-0.7.0.0` resolves.


## Idempotence and Recovery

All source and cabal edits are plain text and re-appliable; `git checkout -- <file>`
reverts any single file. `cabal build`/`cabal test`/`cabal sdist` are safe to repeat. The
git tag is local until pushed and removable with `git tag -d v0.7.0.0`.

If you used the temporary git-pin of `shibuya-core` in `cabal.project` to develop before
`0.7.0.0` reached Hackage, you **must remove that `source-repository-package` block before
publishing the adapter** — a Hackage release may not depend on an unpublished git source.
The release-ready state resolves `shibuya-core 0.7.0.0` purely from Hackage via the
`^>=0.7.0.0` constraint.

The only irreversible step is `cabal upload --publish`; run it last, only after every
other check is green and the user authorizes it. A mistake after publishing is fixed by a
new patch release, never an overwrite.


## Interfaces and Dependencies

Consumed (defined by `docs/plans/12-...`, available from `shibuya-core 0.7.0.0`):

- `Shibuya.Core.Types.Headers` (`= [(ByteString, ByteString)]`), re-exported by
  `Shibuya.Core`.
- `Shibuya.Core.Types.Envelope` with the new `headers :: !(Maybe Headers)` field.

Used from `hw-kafka-client` (already a dependency): `Kafka.Types.Headers`,
`Kafka.Types.headersToList :: Headers -> [(ByteString, ByteString)]`, and (tests)
`Kafka.Types.headersFromList :: [(ByteString, ByteString)] -> Headers`.

Function whose behavior changes:
`Shibuya.Adapter.Kafka.Convert.consumerRecordToEnvelope ::
ConsumerRecord (Maybe ByteString) (Maybe ByteString) -> Envelope (Maybe ByteString)` — now
also sets `headers`.

This plan shares no source files with the other adapter plans (`docs/plans/14-...`,
`docs/plans/15-...`); they live in different repositories. The only shared artifact is the
`shibuya-core` `Envelope`/`Headers` contract, defined upstream by `docs/plans/12-...`.
