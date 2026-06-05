---
id: 15
slug: upgrade-shibuya-kiroku-adapter-for-envelope-headers-field
title: "Upgrade shibuya-kiroku-adapter for Envelope headers field"
kind: exec-plan
created_at: 2026-06-05T16:02:08Z
intention: "intention_01ktc7yzxhex7r1wgt15apscaz"
master_plan: "docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md"
---

# Upgrade shibuya-kiroku-adapter for Envelope headers field

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shibuya-core` `0.7.0.0` added a new field to its central `Envelope` record:
`headers :: !(Maybe Headers)`, where `type Headers = [(ByteString, ByteString)]`. The field
carries the raw, ordered, duplicate-allowing list of headers a broker delivered. Adding it
is a breaking change: every record-syntax construction of `Envelope` stops compiling until
it supplies the field.

The `shibuya-kiroku-adapter` package adapts **Kiroku** — a PostgreSQL-backed append-only
event store for Haskell — into Shibuya's queue-processing framework. It wraps Kiroku's
push-based subscriptions (which deliver `RecordedEvent` rows) behind Shibuya's pull-based
`Adapter` interface. A Kiroku `RecordedEvent` has no broker-header concept: it is a row in
an immutable event log with fields like `eventId`, `eventType`, `globalPosition`,
`createdAt`, and an optional JSONB `metadata` object (used for correlation/causation and
W3C trace context). There is no ordered, raw header stream. Therefore the correct value for
the new `Envelope.headers` field in this adapter is `Nothing` — "this adapter does not
surface broker headers." The trace context already extracted from `metadata` continues to
appear in `traceContext`.

After this change the adapter compiles and tests against `shibuya-core 0.7.0.0`, and a
handler reading `envelope.headers` for a Kiroku event gets `Nothing`.

This plan lives in the `shibuya` repository's `docs/plans/` directory, but the code it
changes is in a **separate git repository**:
`/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` (the multi-package Kiroku repo; the
component to edit is `shibuya-kiroku-adapter`). All edits, builds, tests, commits, and tags
happen in *that* repository.

This plan **hard-depends** on
`docs/plans/12-release-shibuya-core-and-shibuya-metrics-0-7-0-0-and-standardize-cabal-version-3-12.md`:
the adapter sources `shibuya-core` from Hackage and the new `headers` field does not exist
before `0.7.0.0`, so the change cannot compile until `0.7.0.0` is available (from Hackage,
or temporarily git-pinned — see Idempotence and Recovery).

Unlike the other adapters, this repository needs **no** `cabal-version` change: all of its
`.cabal` files already declare `cabal-version: 3.0`, which predates `3.14` and causes none
of the Nix problems that motivate the `3.14` → `3.12` downgrade elsewhere.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: Confirm `shibuya-core 0.7.0.0` is available (Hackage, or git-pin).
- [ ] M1: Bump the `shibuya-core >=0.6 && <0.7` constraint to `>=0.7 && <0.8` (library + test).
- [ ] M1: Add `headers = Nothing` to `toEnvelope` in `Convert.hs`.
- [ ] M1: `cabal build shibuya-kiroku-adapter` succeeds against `shibuya-core 0.7.0.0`.
- [ ] M2: Add/extend a test asserting `headers == Nothing`; `cabal test` is green.
- [ ] M3: Bump `shibuya-kiroku-adapter` `version:` to `0.3.0.0`; add CHANGELOG entry; `nix fmt`.
- [ ] M3: Commit, tag, and (if this adapter is published) publish.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Set `headers = Nothing` in `toEnvelope`.
  Rationale: Kiroku is an append-only PostgreSQL event store; a `RecordedEvent` has no
  ordered, raw broker-header stream. Its JSONB `metadata` already feeds `traceContext` via
  `metadataTraceContext`. There is no faithful broker-header list to surface, so `Nothing`
  is the honest signal that this adapter does not surface headers.
  Date: 2026-06-05

- Decision: Move the `shibuya-core` constraint from `>=0.6 && <0.7` to `>=0.7 && <0.8`
  (not a caret/`^>=` form).
  Rationale: This repository expresses the bound as an explicit range; keep that style and
  simply shift it to admit `0.7.x` and exclude `0.8`. The current `<0.7` upper bound would
  otherwise actively reject the new `0.7.0.0` core.
  Date: 2026-06-05

- Decision: Bump `shibuya-kiroku-adapter` from `0.2.0.0` to `0.3.0.0`.
  Rationale: Requiring a new breaking `shibuya-core` major is itself a breaking change for
  this adapter's consumers; a minor-of-major bump (`0.2` → `0.3`) signals that under PVP.
  Date: 2026-06-05

- Decision: No `cabal-version` change in this repository.
  Rationale: All `.cabal` files are already `cabal-version: 3.0`, which does not trigger the
  Nix issue that the `3.14` → `3.12` downgrade addresses elsewhere.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository to edit is `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku`. Treat
every path below as relative to that directory unless shown absolute. It is a large Cabal
multi-package project; its `cabal.project` declares these packages:

```text
packages:
  kiroku-store
  kiroku-store-migrations
  kiroku-test-support
  shibuya-kiroku-adapter
  kiroku-otel
  kiroku-jitsurei
  kiroku-cli
  kiroku-metrics

with-compiler: ghc-9.12.4

tests: True
benchmarks: True

package codd
  tests: False
  benchmarks: False

allow-newer:
  haxl:time

-- codd and hasql-notifications are pinned from GitHub for release preparation.
source-repository-package
  type: git
  location: https://github.com/shinzui/codd-project.git
  tag: d176b3088f23ef2218c7a1f31835e8ee0c0601aa
  subdir: codd

source-repository-package
  type: git
  location: https://github.com/shinzui/hasql-project.git
  tag: 2bc7ace5db942d87962990bba0b2323ec4c67770
  subdir: hasql-notifications
```

Only **one** package depends on `shibuya-core`: `shibuya-kiroku-adapter`. Its `.cabal` file
is `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`, currently `cabal-version: 3.0`,
`version: 0.2.0.0`, with `shibuya-core >=0.6 && <0.7` in both the library `build-depends`
and the test-suite `build-depends` (around lines 65–93). `shibuya-core` is sourced from
Hackage (it is not git-pinned in `cabal.project`). All other `.cabal` files in the repo
(`kiroku-store`, `kiroku-store-migrations`, `kiroku-test-support`, `kiroku-otel`,
`kiroku-jitsurei`, `kiroku-cli`, `kiroku-metrics`) are also `cabal-version: 3.0` and do not
depend on `shibuya-core`; they are untouched by this plan.

The **single** place that constructs an `Envelope` is `toEnvelope` in
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` (lines 170–182 at the time of
research):

```haskell
toEnvelope :: KirokuEnvelopeAttrs -> RecordedEvent -> Envelope RecordedEvent
toEnvelope attrs event =
    let RecordedEvent{eventId = EventId uuid, eventType = EventType etype, globalPosition = GlobalPosition pos, createdAt = ts, metadata = meta} = event
     in Envelope
            { messageId = MessageId (T.pack (UUID.toString uuid))
            , cursor = Just (CursorInt (fromIntegral pos))
            , partition = Nothing
            , enqueuedAt = Just ts
            , traceContext = metadataTraceContext meta
            , attempt = Nothing
            , attributes = eventAttributes attrs etype pos
            , payload = event
            }
```

There is a second, related site immediately below — `toIngestedAck` (lines 125–140) — but
it does **not** construct an `Envelope` from scratch; it *updates* the one `toEnvelope`
returns:

```haskell
{ envelope = (toEnvelope attrs event){attempt = Just (Attempt attempt)}
, ...
}
```

A record *update* like `(...){attempt = ...}` does not need to mention the new `headers`
field, so this site needs no change once `toEnvelope` itself sets `headers`.

The pattern to mirror for the value choice is `metadataTraceContext` in the same file
(lines 214–223), which extracts W3C trace headers from the event's JSONB `metadata`:

```haskell
metadataTraceContext :: Maybe Value -> Maybe TraceHeaders
metadataTraceContext (Just (Object metadata)) = do
    String traceparent <- KM.lookup (Key.fromString "traceparent") metadata
    let traceparentHeader = ("traceparent", TE.encodeUtf8 traceparent)
        traceHeaders =
            case KM.lookup (Key.fromString "tracestate") metadata of
                Just (String tracestate) -> [traceparentHeader, ("tracestate", TE.encodeUtf8 tracestate)]
                _ -> [traceparentHeader]
    pure traceHeaders
metadataTraceContext _ = Nothing
```

This already supplies `traceContext`; the new `headers` field is `Nothing` and must *not*
duplicate it.

Build/test/format: the repository has a `flake.nix` (`haskell-nix-dev` base; dev shell
provides GHC 9.12.4, cabal, HLS, treefmt, pre-commit). Tests need PostgreSQL. Commands:

```bash
cabal build shibuya-kiroku-adapter
cabal test shibuya-kiroku-adapter      # needs PostgreSQL for integration parts
nix fmt                                # format before committing
nix flake check
```

(Building only `shibuya-kiroku-adapter` rather than `all` avoids rebuilding the entire
Kiroku tree for a change confined to the adapter; `cabal build all` also works.)

Term definitions: **Kiroku** is a PostgreSQL-backed append-only event store. A
**RecordedEvent** is one persisted event row (id, type, stream/global position, timestamp,
payload, metadata). A **subscription** is Kiroku's push mechanism that streams new events;
the adapter bridges it into Shibuya via a bounded queue. **`metadata`** is an optional JSONB
object on the event, holding correlation/causation ids and trace context — not a broker
header list.

The adapter's CHANGELOG is `shibuya-kiroku-adapter/CHANGELOG.md`, currently at `0.2.0.0`
(released 2026-05-31) with an empty Unreleased section.


## Plan of Work

Three milestones: M1 bumps the dependency range and adds the field; M2 proves the value
with a test; M3 versions, documents, and commits (publish only if this adapter is a Hackage
package).

### Milestone 1 — Dependency range and the field

Scope: `shibuya-kiroku-adapter` depends on `shibuya-core >=0.7 && <0.8` and `toEnvelope`
sets `headers = Nothing`. At the end `cabal build shibuya-kiroku-adapter` succeeds against
`shibuya-core 0.7.0.0`.

Edits:

1. Ensure `shibuya-core 0.7.0.0` is resolvable. If `docs/plans/12-...` already published it
   to Hackage, nothing more is needed. To proceed before publication, temporarily add to
   `cabal.project` (remove before release — see Idempotence and Recovery):

   ```text
   source-repository-package
     type: git
     location: https://github.com/<the shibuya repo remote>
     tag: v0.7.0.0
     subdir:
       shibuya-core
       shibuya-metrics
   ```

2. In `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`, change every
   `shibuya-core >=0.6 && <0.7` to `shibuya-core >=0.7 && <0.8` (both the library and the
   test-suite `build-depends`). Confirm with
   `grep -rn "shibuya-core" --include="*.cabal" .`.

3. In `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs`, add `headers =
   Nothing` to `toEnvelope`, placed next to `traceContext`:

   ```haskell
     in Envelope
            { messageId = MessageId (T.pack (UUID.toString uuid))
            , cursor = Just (CursorInt (fromIntegral pos))
            , partition = Nothing
            , enqueuedAt = Just ts
            , traceContext = metadataTraceContext meta
            , headers = Nothing
            , attempt = Nothing
            , attributes = eventAttributes attrs etype pos
            , payload = event
            }
   ```

Acceptance: `cabal build shibuya-kiroku-adapter` succeeds; `grep` shows `>=0.7 && <0.8` on
every `shibuya-core` occurrence.

### Milestone 2 — Test that headers is Nothing

Scope: a test asserts a Kiroku-sourced envelope reports `headers == Nothing`. At the end
`cabal test shibuya-kiroku-adapter` is green.

The test entry point is `shibuya-kiroku-adapter/test/Main.hs`, which already constructs
envelopes via `toEnvelope` in several cases (around lines 68, 88, 90, 97, 114). Add an
assertion on `headers` to one of those existing cases, or add a small focused case that
builds a `RecordedEvent` and a `KirokuEnvelopeAttrs`, calls `toEnvelope`, and checks the
field. Using whatever assertion style the surrounding tests use (HUnit `assertEqual` or
HSpec `shouldBe`):

```haskell
-- with the same RecordedEvent / attrs the neighbouring tests build:
let env = toEnvelope attrs event
assertEqual "headers" Nothing env.headers
```

If the test for a metadata-bearing event (one whose JSONB `metadata` carries
`traceparent`) is nearby, assert `headers == Nothing` there too, to prove trace metadata is
deliberately not echoed into `headers`.

Acceptance: `cabal test shibuya-kiroku-adapter` runs green (PostgreSQL must be available for
any integration cases; the `toEnvelope` assertions are pure).

### Milestone 3 — Version, changelog, commit

Scope: bump the adapter version, document, format, commit, tag. At the end the change is a
clean commit on the Kiroku repo.

Edits: set `version: 0.3.0.0` in `shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal`.
Add a CHANGELOG entry to `shibuya-kiroku-adapter/CHANGELOG.md`:

```markdown
## 0.3.0.0 — 2026-06-05

### Changed

- Require `shibuya-core >=0.7 && <0.8`. `Envelope` now carries a
  `headers :: Maybe Headers` field; `toEnvelope` sets it to `Nothing`,
  because Kiroku events carry no ordered, raw broker headers. W3C trace
  context continues to be surfaced via `traceContext` from event metadata.
```

Then format and commit per Concrete Steps. If `shibuya-kiroku-adapter` is published to
Hackage, follow the same gated `cabal sdist` + `cabal upload --publish` flow the other
adapter plans describe; if it is consumed only locally/as part of Kiroku, a tagged commit
is sufficient — record which in the Decision Log when you confirm it.

Acceptance: a commit exists bumping the adapter to `0.3.0.0` with the field set and tests
green; `nix fmt` leaves the tree clean.


## Concrete Steps

Run everything from `/Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku` inside its
`nix develop` shell.

```bash
# M1: after editing the constraint and Convert.hs
grep -rn "shibuya-core" --include="*.cabal" .    # expect >=0.7 && <0.8
cabal build shibuya-kiroku-adapter

# M2:
cabal test shibuya-kiroku-adapter

# M3: after version bump + changelog
nix fmt
git add -A
git commit -m "feat(shibuya-kiroku-adapter)!: require shibuya-core 0.7 and set Envelope.headers

toEnvelope now sets the new Envelope.headers field to Nothing (Kiroku events
carry no broker headers). Move the shibuya-core bound to >=0.7 && <0.8 and
bump the adapter to 0.3.0.0.

MasterPlan: docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md
ExecPlan: docs/plans/15-upgrade-shibuya-kiroku-adapter-for-envelope-headers-field.md
Intention: intention_01ktc7yzxhex7r1wgt15apscaz"

git tag -a shibuya-kiroku-adapter-v0.3.0.0 -m "shibuya-kiroku-adapter 0.3.0.0"
```

(Use a package-qualified tag like `shibuya-kiroku-adapter-v0.3.0.0` if the Kiroku repo
already tags per-package; if it tags the whole repo, follow that convention instead and
record it in the Decision Log.)


## Validation and Acceptance

1. `grep -rn "shibuya-core" --include="*.cabal" .` shows `>=0.7 && <0.8` on every
   occurrence; `shibuya-kiroku-adapter.cabal` reads `version: 0.3.0.0`.
2. `cabal build shibuya-kiroku-adapter` succeeds with `shibuya-core 0.7.0.0` resolved.
3. `cabal test shibuya-kiroku-adapter` runs green; the new assertion proves
   `env.headers == Nothing` for a Kiroku-sourced envelope, including a metadata-bearing
   event, confirming trace metadata is not echoed into `headers`.
4. A commit bumping the adapter to `0.3.0.0` exists with the field set and tests green.


## Idempotence and Recovery

All edits are plain text and re-appliable; `git checkout -- <file>` reverts any single
file. `cabal build`/`cabal test` are repeatable. The git tag is local until pushed and
removable with `git tag -d <tag>`.

If you temporarily git-pinned `shibuya-core` in `cabal.project` to develop before `0.7.0.0`
reached Hackage, **remove that `source-repository-package` block before any publish** — a
Hackage release must not depend on an unpublished git source. The release-ready state
resolves `shibuya-core 0.7.0.0` from Hackage via `>=0.7 && <0.8`. If this adapter is not
published to Hackage, the git-pin may remain only if the rest of the Kiroku repo
deliberately develops against pinned sources; prefer relying on the published `0.7.0.0`
once it exists.


## Interfaces and Dependencies

Consumed (defined by `docs/plans/12-...`, available from `shibuya-core 0.7.0.0`):

- `Shibuya.Core.Types.Headers` (`= [(ByteString, ByteString)]`), re-exported by
  `Shibuya.Core`.
- `Shibuya.Core.Types.Envelope` with the new `headers :: !(Maybe Headers)` field.

Function whose construction changes:
`Shibuya.Adapter.Kiroku.Convert.toEnvelope :: KirokuEnvelopeAttrs -> RecordedEvent ->
Envelope RecordedEvent` — now also sets `headers = Nothing`. The neighbouring
`toIngestedAck` performs only a record *update* on the result and needs no change.

This plan shares no source files with the other adapter plans (`docs/plans/13-...`,
`docs/plans/14-...`); they live in different repositories. The only shared artifact is the
`shibuya-core` `Envelope`/`Headers` contract, defined upstream by `docs/plans/12-...`.
