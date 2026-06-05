---
id: 14
slug: upgrade-shibuya-pgmq-adapter-for-envelope-headers-field-and-cabal-version-3-12
title: "Upgrade shibuya-pgmq-adapter for Envelope headers field and cabal-version 3.12"
kind: exec-plan
created_at: 2026-06-05T16:02:08Z
intention: "intention_01ktc7yzxhex7r1wgt15apscaz"
master_plan: "docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md"
---

# Upgrade shibuya-pgmq-adapter for Envelope headers field and cabal-version 3.12

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

`shibuya-core` `0.7.0.0` added a new field to its central `Envelope` record:
`headers :: !(Maybe Headers)`, where `type Headers = [(ByteString, ByteString)]`. The field
carries the raw, ordered, duplicate-allowing list of headers a *broker* delivered. Adding
it is a breaking change: every record-syntax construction of `Envelope` stops compiling
until it supplies the field.

The `shibuya-pgmq-adapter` package turns messages read from PGMQ — a PostgreSQL-backed
message queue implemented by the `pgmq` Postgres extension — into Shibuya `Envelope`s.
Unlike Kafka, PGMQ has no notion of an ordered, raw broker-header list: a PGMQ message is a
JSONB body plus a separate optional JSONB `headers` object, and that `headers` object is
unordered user metadata with unique keys, not a faithful broker-header stream. The adapter
already reads that JSONB object to pull out a partition hint and W3C trace context. Because
PGMQ does not surface real broker headers, the correct value for the new `Envelope.headers`
field in this adapter is `Nothing` — meaning "this adapter does not surface broker
headers." (See the Decision Log for the alternative that was considered and rejected.)

After this change the adapter compiles and tests against `shibuya-core 0.7.0.0`, and a
handler reading `envelope.headers` for a PGMQ-sourced message gets `Nothing`, which
correctly signals "no broker headers here" rather than fabricating an ordered list from an
unordered JSON object.

This plan also lowers `cabal-version: 3.14` to `3.12` in this repository's three `.cabal`
files. The `cabal-version` line is the first line of a `.cabal` file and selects the
package-description format version. Some Nix toolchains ship a `Cabal` library older than
`3.14` and reject files that declare `cabal-version: 3.14`. None of this repository's
`.cabal` files use any `3.14`-only syntax, so `3.12` is a safe, behavior-preserving
downgrade that unblocks those Nix users — the same housekeeping the core repository does in
`docs/plans/12-...`.

This plan lives in the `shibuya` repository's `docs/plans/` directory, but the code it
changes is in a **separate git repository**:
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`. All edits, builds,
tests, commits, and tags happen in *that* repository.

This plan **hard-depends** on
`docs/plans/12-release-shibuya-core-and-shibuya-metrics-0-7-0-0-and-standardize-cabal-version-3-12.md`:
the adapter sources `shibuya-core` from Hackage and the new `headers` field does not exist
before `0.7.0.0`, so the change cannot compile until `0.7.0.0` is available (from Hackage,
or temporarily git-pinned — see Idempotence and Recovery).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: Lowered `cabal-version: 3.14` → `3.12` in all three `.cabal` files. (2026-06-05)
- [x] M1: Verified `shibuya-core 0.7.0.0` via temporary local-source pin (core + metrics; removed before commit). (2026-06-05)
- [x] M1: Bumped `shibuya-core ^>=0.6.0.0` → `^>=0.7.0.0` (all four occurrences) and the example's `shibuya-metrics ^>=0.7.0.0`. (2026-06-05)
- [x] M1: Added `headers = Nothing` to `pgmqMessageToEnvelope` (+ haddock incl. a Future note). (2026-06-05)
- [x] M1: `cabal build all` succeeds against local `shibuya-core 0.7.0.0` (inside `nix develop`). (2026-06-05)
- [x] M2: Added unit tests asserting `headers == Nothing` (no-headers and non-empty-JSONB cases); Convert spec green — 22 examples. (2026-06-05)
- [x] M3: Bumped `shibuya-pgmq-adapter` `version:` to `0.7.0.0`; added CHANGELOG entry; removed temp pin; `nix fmt` clean. (2026-06-05)
- [x] M3: Committed `48c27ba` and tagged `v0.7.0.0` in the pgmq repo. (2026-06-05)
- [ ] M3 (privileged, owned by user): publish `shibuya-pgmq-adapter 0.7.0.0` to Hackage (after `shibuya-core 0.7.0.0`).


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Set `headers = Nothing` in `pgmqMessageToEnvelope`.
  Rationale: The new `Envelope.headers` field is specified as the faithful, *ordered,
  duplicate-allowing* list of raw broker headers. PGMQ has no such thing: its per-message
  `headers` is an optional JSONB *object* (unordered, unique string keys), used here only
  to derive a partition hint and W3C trace context. Converting that object into an ordered
  `[(ByteString, ByteString)]` would invent an order and a fidelity PGMQ never guaranteed,
  and would duplicate what `traceContext` already surfaces. `Nothing` is the honest signal
  "this adapter does not surface broker headers."
  Alternative considered: `headers = Just (flatten msg.headers)` — flatten the JSONB object
  to a list. Rejected for the fidelity/ordering reasons above; if a future requirement
  wants PGMQ user-metadata exposed, it should get its own clearly-named field rather than
  masquerading as broker headers.
  Date: 2026-06-05

- Decision (confirmed with user, 2026-06-05): keep `headers = Nothing` for the pgmq
  adapter; do not flatten the JSONB `headers` object into the field at this time.
  Rationale: The user asked whether the pgmq adapter should leverage the field and chose
  `Nothing`. A future use case does exist — surfacing arbitrary producer-supplied pgmq
  headers (beyond the `x-pgmq-group`/`traceparent`/`tracestate` keys already special-cased)
  so handlers can read them — but it requires a lossy JSON-object → ordered-list mapping
  and was deferred until a concrete need appears. A "Future:" note documenting this option
  was added to the haddock above `pgmqMessageToEnvelope` in
  `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` so the next maintainer sees it.
  Date: 2026-06-05

- Decision: Lower `cabal-version` from `3.14` to `3.12` in all three `.cabal` files as part
  of this plan.
  Rationale: This repository's files declare `3.14`, which blocks Nix users with an older
  bundled Cabal. No `3.14`-only syntax is used, so the downgrade is safe. Folding it into
  this adapter plan keeps each repository's changes self-contained in one plan.
  Date: 2026-06-05

- Decision: Bump `shibuya-pgmq-adapter` to `0.7.0.0`; bump the sibling
  `shibuya-pgmq-example` and `shibuya-pgmq-adapter-bench` (`0.1.0.0`) only if a release is
  desired — they are internal and may stay at `0.1.0.0`, but their `shibuya-core`
  constraint must still move to `^>=0.7.0.0` so the workspace resolves.
  Rationale: Only `shibuya-pgmq-adapter` is the published artifact tracking the core
  version; the example/bench packages are internal but share the `cabal.project` and so
  must accept the new core.
  Date: 2026-06-05


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

As of 2026-06-05 the adapter is upgraded and released locally (commit `48c27ba`, tag
`v0.7.0.0`). `pgmqMessageToEnvelope` sets `headers = Nothing`; the Convert spec reports 22
examples passing, including two new cases proving the field is `Nothing` even when the
pgmq JSONB `headers` object is non-empty. All three `.cabal` files are now `cabal-version:
3.12`.

Two things surfaced beyond the original plan. First, the local-source pin needed to include
`shibuya-metrics` as well as `shibuya-core`, because `shibuya-pgmq-example` depends on
`shibuya-metrics` (Hackage 0.6.0.0) and that transitively pinned `shibuya-core` back to
0.6.0.0; the example's `shibuya-metrics` constraint also had to move to `^>=0.7.0.0`.
Second, the user confirmed the `headers = Nothing` choice and asked for a forward-looking
note, so a `Future:` comment documenting the option to surface producer-supplied pgmq
headers was added to `Shibuya.Adapter.Pgmq.Convert` and to this plan's Decision Log.

The remaining step is the privileged Hackage upload of the adapter, owned by the user and
gated behind the `shibuya-core 0.7.0.0` publish.


## Context and Orientation

The repository to edit is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`. Treat every path
below as relative to that directory unless shown absolute. It is a Cabal multi-package
project whose `cabal.project` declares three packages:

```text
packages:
  shibuya-pgmq-adapter
  shibuya-pgmq-adapter-bench
  shibuya-pgmq-example
```

The full `cabal.project` is:

```text
packages:
  shibuya-pgmq-adapter
  shibuya-pgmq-adapter-bench
  shibuya-pgmq-example

-- hasql-migration: shinzui fork patches the Hackage release for hasql 1.10's
-- Statement API change (Statement constructor no longer public) and moves to
-- crypton 1.x. The Hackage hasql-migration-0.3.1 release still targets the
-- pre-1.10 API and will not build against current hasql.
source-repository-package
  type: git
  location: https://github.com/shinzui/hasql-migration
  tag: 4aaff6c0919d1fe8e1c248c3ce4ce05775c59c8c

-- Allow newer for proto-lens packages (GHC 9.12 support)
allow-newer:
  proto-lens:base,
  proto-lens:ghc-prim,
  proto-lens-runtime:base,
  proto-lens-protobuf-types:base,
  proto-lens-protobuf-types:ghc-prim
```

Note `shibuya-core` is sourced from Hackage (only `hasql-migration` is git-pinned).

The three `.cabal` files and their current state:

- `shibuya-pgmq-adapter/shibuya-pgmq-adapter.cabal`: `cabal-version: 3.14`,
  `version: 0.6.0.0`, dependency `shibuya-core ^>=0.6.0.0` (around line 49); the test suite
  also depends on `shibuya-core`.
- `shibuya-pgmq-example/shibuya-pgmq-example.cabal`: `cabal-version: 3.14`,
  `version: 0.1.0.0`, `shibuya-core ^>=0.6.0.0` (around line 107).
- `shibuya-pgmq-adapter-bench/shibuya-pgmq-adapter-bench.cabal`: `cabal-version: 3.14`,
  `version: 0.1.0.0`, `shibuya-core ^>=0.6.0.0` (around line 68).

The **single** place that constructs an `Envelope` is the function
`pgmqMessageToEnvelope` in
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` (lines 94–105 at the time of
research):

```haskell
pgmqMessageToEnvelope :: Pgmq.Message -> Envelope Value
pgmqMessageToEnvelope msg =
  Envelope
    { messageId = messageIdToShibuya msg.messageId,
      cursor = Just (pgmqMessageIdToCursor msg.messageId),
      partition = extractPartition msg.headers,
      enqueuedAt = Just msg.enqueuedAt,
      traceContext = extractTraceHeaders msg.headers,
      attempt = Just (readCountToAttempt msg.readCount),
      attributes = HashMap.empty,
      payload = Pgmq.unMessageBody msg.body
    }
```

Here `msg :: Pgmq.Message` is the PGMQ message record from the adapter's `pgmq` client.
Its `msg.headers :: Maybe Value` is an Aeson JSON value (a JSONB column), *not* an ordered
header list; `extractPartition` and `extractTraceHeaders` already read it. Every other
`Envelope { ... }` occurrence in the repository is a **pattern match**, not a construction
(in `test/Shibuya/Adapter/Pgmq/ConvertSpec.hs`, `PropertySpec.hs`, `IntegrationSpec.hs`,
and `shibuya-pgmq-example/app/Consumer.hs`). Pattern matches do not need the new field
unless they exhaustively bind all fields with `{..}` or positional syntax — these use named
fields, so they keep compiling unchanged. (If any test pattern uses `Envelope{..}` record
wildcards and then references `headers`, that is fine; if the build complains about an
unused/again-needed binding, adjust only that match.)

The pattern to be aware of for the value choice: `extractTraceHeaders` already extracts the
W3C trace headers from the JSONB into `traceContext`. The new `headers` field is *not* a
second copy of that; per the decision above it is `Nothing` for this adapter.

Build/test/format: the repository has a `flake.nix` (flake-parts on the `haskell-nix-dev`
base; dev shell provides GHC 9.12.4, cabal, HLS, PostgreSQL, `jq`, `process-compose`,
`just`) and `nix/treefmt.nix`/`nix/pre-commit.nix`. Tests require a PostgreSQL instance
(provided via ephemeral Postgres in the dev shell). Commands:

```bash
cabal build all
cabal test           # needs PostgreSQL available (ephemeral-pg / dev shell)
nix fmt              # format before committing
nix flake check
```

Term definitions: **PGMQ** is the `pgmq` PostgreSQL extension implementing a message queue;
its `read()` returns columns `msg_id`, `read_ct`, `enqueued_at`, `vt` (visibility
timeout), `message` (JSONB body), and `headers` (optional JSONB metadata object).
**JSONB** is PostgreSQL's binary JSON column type — an *object* with unique keys and no
guaranteed ordering, which is exactly why it is not a faithful broker-header list.


## Plan of Work

Three milestones: M1 downgrades the cabal-version, bumps the dependency, and adds the
field; M2 proves the value with a test; M3 versions, documents, and releases.

### Milestone 1 — cabal-version downgrade, dependency bump, and the field

Scope: all three `.cabal` files declare `cabal-version: 3.12` and depend on
`shibuya-core ^>=0.7.0.0`, and `pgmqMessageToEnvelope` sets `headers = Nothing`. At the end
`cabal build all` succeeds against `shibuya-core 0.7.0.0`.

Edits:

1. In each of the three `.cabal` files, change the first line
   `cabal-version: 3.14` → `cabal-version: 3.12`.

2. Ensure `shibuya-core 0.7.0.0` is resolvable. If `docs/plans/12-...` already published it
   to Hackage, nothing more is needed. To proceed in parallel before publication,
   temporarily add a git pin to `cabal.project` (remove before release — see Idempotence
   and Recovery):

   ```text
   source-repository-package
     type: git
     location: https://github.com/<the shibuya repo remote>
     tag: v0.7.0.0
     subdir:
       shibuya-core
       shibuya-metrics
   ```

3. Bump the `shibuya-core` constraint from `^>=0.6.0.0` to `^>=0.7.0.0` in all three
   `.cabal` files (including the test-suite stanza in `shibuya-pgmq-adapter.cabal`).
   Confirm with `grep -rn "shibuya-core" --include="*.cabal" .`.

4. In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs`, add `headers = Nothing`
   to `pgmqMessageToEnvelope`, placed next to `traceContext`:

   ```haskell
   pgmqMessageToEnvelope msg =
     Envelope
       { messageId = messageIdToShibuya msg.messageId,
         cursor = Just (pgmqMessageIdToCursor msg.messageId),
         partition = extractPartition msg.headers,
         enqueuedAt = Just msg.enqueuedAt,
         traceContext = extractTraceHeaders msg.headers,
         headers = Nothing,
         attempt = Just (readCountToAttempt msg.readCount),
         attributes = HashMap.empty,
         payload = Pgmq.unMessageBody msg.body
       }
   ```

Acceptance: `cabal build all` succeeds; `grep` confirms `cabal-version: 3.12` (three
matches) and `shibuya-core ^>=0.7.0.0` on every bounded occurrence.

### Milestone 2 — Test that headers is Nothing

Scope: a test asserts a PGMQ-sourced envelope reports `headers == Nothing`. At the end
`cabal test` is green.

In `test/Shibuya/Adapter/Pgmq/ConvertSpec.hs` (the existing unit spec that already exercises
`pgmqMessageToEnvelope`), add an assertion to an existing example or a small new one that
builds a `Pgmq.Message` and checks `env.headers`:

```haskell
  it "does not surface broker headers (headers is Nothing)" $ do
    let env = pgmqMessageToEnvelope sampleMessage
    env.headers `shouldBe` Nothing
```

Reuse whatever `sampleMessage`/builder the surrounding specs already use to construct a
`Pgmq.Message`; if there is a helper that builds a message with a non-empty JSONB `headers`
object (used by the partition/trace tests), assert `headers == Nothing` even for that
case, to prove the JSONB object is deliberately *not* copied into the new field.

Acceptance: `cabal test` runs green (PostgreSQL must be available for the integration
parts; the `ConvertSpec` unit assertions are pure and do not need it).

### Milestone 3 — Version, changelog, tag, publish

Scope: bump versions, document, format, commit, tag, and (gated) publish. At the end the
release exists in git and, once authorized, on Hackage.

Edits: set `version: 0.7.0.0` in `shibuya-pgmq-adapter.cabal` (the published package);
optionally bump the example/bench packages, or leave them at `0.1.0.0`. Prepend a CHANGELOG
entry to `shibuya-pgmq-adapter/CHANGELOG.md`:

```markdown
## 0.7.0.0 — 2026-06-05

### Changed

- Require `shibuya-core ^>=0.7.0.0`. `Envelope` now carries a
  `headers :: Maybe Headers` field; `pgmqMessageToEnvelope` sets it to
  `Nothing`, because PGMQ messages do not carry an ordered, raw broker-header
  stream (the per-message JSONB `headers` object remains the source for the
  partition hint and W3C trace context, surfaced via `partition` and
  `traceContext`).
- Lower `cabal-version` from `3.14` to `3.12` in all packages so Nix
  toolchains with an older bundled Cabal can build the adapter. No
  package-description syntax requiring 3.14 was in use.
```

Then format, commit, tag, and (privileged) publish per Concrete Steps.

Acceptance: `git tag` shows `v0.7.0.0`; the sdist `.cabal` reports `version: 0.7.0.0` and
`cabal-version: 3.12`; after authorized upload, the Hackage page resolves.


## Concrete Steps

Run everything from
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter` inside its
`nix develop` shell.

```bash
# M1: after editing cabal-version, constraints, and Convert.hs
grep -rn "cabal-version" --include="*.cabal" .   # expect three 3.12
grep -rn "shibuya-core" --include="*.cabal" .    # expect ^>=0.7.0.0 where bounded
cabal build all

# M2:
cabal test

# M3: after version bump + changelog
nix fmt
git add -A
git commit -m "feat!: require shibuya-core 0.7 (Envelope headers) and lower cabal-version to 3.12

pgmqMessageToEnvelope now sets the new Envelope.headers field to Nothing
(PGMQ surfaces no ordered broker headers). Bump shibuya-core to ^>=0.7.0.0,
bump shibuya-pgmq-adapter to 0.7.0.0, and lower cabal-version 3.14 -> 3.12
across the repo for Nix compatibility.

MasterPlan: docs/masterplans/2-headers-field-adapter-upgrade-and-core-0-7-0-0-release.md
ExecPlan: docs/plans/14-upgrade-shibuya-pgmq-adapter-for-envelope-headers-field-and-cabal-version-3-12.md
Intention: intention_01ktc7yzxhex7r1wgt15apscaz"

git tag -a v0.7.0.0 -m "shibuya-pgmq-adapter 0.7.0.0"
cabal sdist shibuya-pgmq-adapter
tar -xzf dist-newstyle/sdist/shibuya-pgmq-adapter-0.7.0.0.tar.gz -O \
  shibuya-pgmq-adapter-0.7.0.0/shibuya-pgmq-adapter.cabal | head -5
```

Privileged publish — only after explicit user authorization (Hackage uploads are
irreversible):

```bash
cabal upload --publish dist-newstyle/sdist/shibuya-pgmq-adapter-0.7.0.0.tar.gz
```


## Validation and Acceptance

1. `grep -rn "cabal-version" --include="*.cabal" .` shows three matches, all `3.12`.
2. `grep -rn "shibuya-core" --include="*.cabal" .` shows `^>=0.7.0.0` on every bounded
   occurrence; `shibuya-pgmq-adapter.cabal` reads `version: 0.7.0.0`.
3. `cabal build all` succeeds with `shibuya-core 0.7.0.0` resolved.
4. `cabal test` runs green; the new assertion proves `env.headers == Nothing` for a
   PGMQ-sourced envelope — including one whose JSONB `headers` object is non-empty —
   confirming the adapter deliberately does not fabricate broker headers.
5. The git tag `v0.7.0.0` exists; the sdist `.cabal` reports `version: 0.7.0.0` and
   `cabal-version: 3.12`. After authorized upload, the Hackage page resolves.


## Idempotence and Recovery

All edits are plain text and re-appliable; `git checkout -- <file>` reverts any single
file. `cabal build`/`cabal test`/`cabal sdist` are repeatable. The git tag is local until
pushed and removable with `git tag -d v0.7.0.0`.

If you temporarily git-pinned `shibuya-core` in `cabal.project` to develop before `0.7.0.0`
reached Hackage, **remove that `source-repository-package` block before publishing** — a
Hackage release must not depend on an unpublished git source. The release-ready state
resolves `shibuya-core 0.7.0.0` from Hackage via `^>=0.7.0.0`.

The only irreversible step is `cabal upload --publish`; run it last, only after all checks
are green and the user authorizes it. A post-publish mistake is fixed by a new patch
release, never an overwrite.


## Interfaces and Dependencies

Consumed (defined by `docs/plans/12-...`, available from `shibuya-core 0.7.0.0`):

- `Shibuya.Core.Types.Headers` (`= [(ByteString, ByteString)]`), re-exported by
  `Shibuya.Core`.
- `Shibuya.Core.Types.Envelope` with the new `headers :: !(Maybe Headers)` field.

Function whose construction changes:
`Shibuya.Adapter.Pgmq.Convert.pgmqMessageToEnvelope :: Pgmq.Message -> Envelope Value` —
now also sets `headers = Nothing`.

This plan shares no source files with the other adapter plans (`docs/plans/13-...`,
`docs/plans/15-...`); they live in different repositories. The only shared artifact is the
`shibuya-core` `Envelope`/`Headers` contract, defined upstream by `docs/plans/12-...`. The
`cabal-version: 3.12` standardization is the same cross-cutting concern that `docs/plans/12-...`
applies to the core repository; here it is applied to the pgmq repository.
