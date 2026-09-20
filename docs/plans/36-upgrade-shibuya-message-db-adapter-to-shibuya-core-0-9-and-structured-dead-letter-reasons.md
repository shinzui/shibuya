---
id: 36
slug: upgrade-shibuya-message-db-adapter-to-shibuya-core-0-9-and-structured-dead-letter-reasons
title: "Upgrade shibuya-message-db-adapter to shibuya-core 0.9 and structured dead-letter reasons"
kind: exec-plan
created_at: 2026-09-16T23:04:43Z
intention: intention_01m2ycc3fxedxtw5339e0efzy1
master_plan: "docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-16T23:04:43Z
  revisions:
    - model: "gpt-5.6-sol"
      harness: "codex-cli"
      at: 2026-09-20T03:15:22Z
      mode: "update"
      note: "Align the core target with 0.9.0.2 and inherit the active intention"
---

# Upgrade shibuya-message-db-adapter to shibuya-core 0.9 and structured dead-letter reasons

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

shibuya-message-db-adapter connects the shibuya queue-processing framework to message-db, a
PostgreSQL event store. It is pinned to `shibuya-core ^>=0.5.0.0`, four breaking releases
behind the current 0.9 line, so it cannot be built with any current core and cannot be used
by an application that also uses the pgmq, Kafka, or kiroku adapters. Its dead-letter metadata
renderer is an exhaustive match over the three dead-letter reasons that existed before 0.9; if
the bound were simply widened, the first message an application dead-letters with the 0.9
`ApplicationFailure` reason would crash the finalizer with an incomplete-pattern error.

After this plan the adapter builds against shibuya-core 0.9 (0.9.0.2 once
`docs/plans/33-remove-the-idle-linked-master-loop-that-deadlocks-bare-waitapp-callers.md` has
released it, 0.9.0.1 otherwise), its test suite passes against a real PostgreSQL, a message
dead-lettered with `ApplicationFailure` lands in the dead-letter stream with its code and
detail stored as separate metadata fields, and the adapter is tagged 0.2.0.0. A reader can
see it working by running the suite and by running the `dead-letter-demo` example against the
local database and reading the `$DeadLetter` message's metadata back with `psql`.


## Progress

- [ ] Milestone 1: bounds raised, `Envelope` construction fixed, everything compiles against shibuya-core 0.9 with `-Werror=incomplete-patterns`.
- [ ] Milestone 2: dead-letter metadata carries `deadLetterReasonCode` and `deadLetterReasonDetail`; legacy `deadLetterReason` string unchanged for the three built-in reasons; `ApplicationFailure` round-trips in a database test.
- [ ] Milestone 3: examples and README updated; suite green; version 0.2.0.0, changelog, tag.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Keep the existing `deadLetterReason` metadata string byte-for-byte for the three built-in reasons and derive it from the 0.9 projections as `<code>:<detail>` (no space) or `<code>` alone.
  Rationale: The adapter's own format is `poison_pill:<detail>` with no space after the colon, whereas shibuya-core's `renderDeadLetterReason` produces `poison_pill: <detail>` with a space. Switching to the core renderer would silently change every existing consumer's parsed value. Composing the string from `deadLetterReasonCode` and `deadLetterReasonDetail` preserves the adapter's format exactly and extends it to `ApplicationFailure` as `<code>:<detail>` without a constructor match.
  Date: 2026-09-16

- Decision: Add the structured fields `deadLetterReasonCode` and `deadLetterReasonDetail` alongside the legacy string rather than replacing it.
  Rationale: This mirrors what shibuya-pgmq-adapter 0.14.0.0 did (`dead_letter_reason_code` and `dead_letter_reason_detail` beside `dead_letter_reason`), and message-db metadata is JSON, so additive keys break no reader. Removing the legacy key is a separate, gated decision as it was for pgmq.
  Date: 2026-09-16

- Decision: Fail the build on incomplete pattern matches with `-Werror=incomplete-patterns`.
  Rationale: The kiroku adapter adopted exactly this after the 0.9 upgrade (its cabal comment explains that a translation between two dependency-owned sum types silently loses a case when upstream adds a constructor). Hackage rejects an unconditional `-Werror`, so the targeted flag is used.
  Date: 2026-09-16

- Decision: Version 0.2.0.0, git tag only.
  Rationale: The dependency major bump changes the types the adapter exposes to callers through shibuya-core, which is a breaking change under the PVP. The package is not on Hackage (`cabal info shibuya-message-db-adapter` finds nothing) and has no tags today, so the release is a tag on `master`; publishing to Hackage is the maintainer's separate decision.
  Date: 2026-09-16

- Decision: Target shibuya-core `>=0.9.0.2 && <0.10` for the final release.
  Rationale: Plan 33's internal-only liveness fix is a PVP patch and ships alone as 0.9.0.2;
  this adapter can consume that fix without waiting for plan 34's dependency-bound release.
  Date: 2026-09-20 UTC


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The adapter repository is `/Users/shinzui/Keikaku/work/libraries/haskell/shibuya-message-db-adapter`
(Mori name `shinzui/shibuya-message-db-adapter`, remote `github.com/shinzui/shibuya-message-db-adapter`,
branch `master`, working tree clean as of 2026-09-16, last code change 2026-05-05). It has two
packages. `shibuya-message-db-adapter/` holds the library (modules `Shibuya.Adapter.MessageDb`,
`.Config`, `.Convert`, `.Internal`, `.Internal.Dlq`, `.Internal.InflightState`), a demo
executable `shibuya-message-db-adapter-demo` at `shibuya-message-db-adapter/app/Demo.hs`, and
the test suite `shibuya-message-db-adapter-test` under `shibuya-message-db-adapter/test/`
(`Main.hs`, `TestEnv.hs`, and eleven `*Test.hs` modules under
`test/Shibuya/Adapter/MessageDb/`). `shibuya-message-db-adapter-jitsurei/` holds five example
executables (`basic-consumer`, `retry-demo`, `dead-letter-demo`, `checkpoint-restart`,
`multi-partition`) under `app/`.

The build and test environment comes from the repository's Nix flake and `Justfile`. `just
process-up` starts PostgreSQL with the message-db schema through process-compose; `just
bootstrap-message-db` creates the database and installs the schema from the message-db
checkout at `/Users/shinzui/Keikaku/hub/event-sourcing/message-db-project/message-db`; `just
build` and `just test` wrap `cabal build` and `cabal test`. Some tests (`CheckpointResumeTest`,
`RetryDlqHaltResumeTest`, `RetryBufferTest`) start their own temporary PostgreSQL through
`ephemeral-pg` and do not need the process-compose instance; the others use `TestEnv.hs`.

Dependency declarations to change are in `shibuya-message-db-adapter/shibuya-message-db-adapter.cabal`:
line 71 `shibuya-core ^>=0.5.0.0` (library), and `effectful ^>=2.6.1.0` and `effectful-core
^>=2.6.1.0` at lines 63 to 64; the test suite and demo stanzas name `shibuya-core` without a
bound. `shibuya-message-db-adapter-jitsurei/shibuya-message-db-adapter-jitsurei.cabal` line 51
declares `shibuya-core ^>=0.5.0.0` and line 52 `shibuya-message-db-adapter ^>=0.1.0.0`. The
`common warnings` stanza at lines 30 to 35 of the library cabal file carries the `-Wall`
family of flags and is where `-Werror=incomplete-patterns` goes.

What changed in shibuya-core between 0.5 and 0.9 that this adapter touches, taken from
`shibuya-core/CHANGELOG.md` and `docs/user/migrating-to-0.8.md` and `docs/user/migrating-to-0.9.md`
in the shibuya repository:

0.6.0.0 upgraded the OpenTelemetry packages and renamed the emitted `messaging.operation` key;
the adapter has no OpenTelemetry dependency of its own and only extracts W3C trace headers from
message metadata, so nothing changes for it.

0.7.0.0 added `headers :: !(Maybe Headers)` to `Envelope`, with `Nothing` meaning the adapter
does not surface headers. `Shibuya.Adapter.MessageDb.Convert.messageToEnvelope` (lines 45 to
58 of `Convert.hs`) builds `Envelope` as a full record literal and must add `headers = Nothing`.
Any other full `Envelope { ... }` literal in tests or examples needs the same field; the
`multi-partition` example builds an `Ingested` record by hand around line 183 of
`shibuya-message-db-adapter-jitsurei/app/MultiPartition.hs`, so check it. shibuya-core 0.8 also
exports `mkEnvelope :: MessageId -> msg -> Envelope msg` from `Shibuya.Core.Types`, which
fills every optional field with a default; using it and then setting `cursor`, `enqueuedAt`,
and `traceContext` with record update is the forward-compatible form, but adding the one
field is the smaller change and either is acceptable.

0.8.0.0 made handlers receive `Message es msg` instead of `Ingested es msg`, gave `runApp` an
`AppConfig` argument, and moved runner internals under `Shibuya.Internal.*`. None of that
reaches this adapter's code: its library constructs `Ingested` values (still exported with its
record constructor from `Shibuya.Core.Ingested`) and never calls `runApp`; its tests and
examples consume the adapter's `source` stream directly and call `finalize` themselves through
`AckHandle` (for example `handle ... Ingested{envelope = Envelope{payload = msg}, ack =
AckHandle finalize}` in `test/Shibuya/Adapter/MessageDb/DeadLetterSkipAndLogTest.hs` line 119
and the same pattern in every other test and example). Those keep compiling. 0.8 also wrote
down the `AckHandle` contract in `shibuya-core/src/Shibuya/Core/AckHandle.hs`: the framework
calls `finalize` at most once per delivery with a resolved decision, except that it may retry
the same decision after a transient finalizer exception, so finalization must be idempotent
or phase-tracked. This adapter already tracks in-flight phases in `Internal/InflightState.hs`;
the plan does not change that logic, but Milestone 1 confirms the existing DLQ write is safe
to repeat (it already treats an idempotent-duplicate write as success, per the comment above
`writeDlqMessage` in `Internal/Dlq.hs`).

0.9.0.0 added `ApplicationFailure !DeadLetterCode !Text` to `DeadLetterReason` and three total
projections in `Shibuya.Core.Ack`: `deadLetterReasonCode :: DeadLetterReason -> DeadLetterCode`,
`deadLetterReasonDetail :: DeadLetterReason -> Maybe Text`, and `renderDeadLetterReason ::
DeadLetterReason -> Text`, plus `deadLetterCodeText :: DeadLetterCode -> Text` and the
validating constructor `mkDeadLetterCode :: Text -> Either Text DeadLetterCode`. The built-in
codes are `poison_pill`, `invalid_payload`, and `max_retries_exceeded`; application codes are
lowercase dot-separated identifiers such as `example.policy.rejected`. In this adapter the
exhaustive match is `renderReason` at lines 166 to 170 of
`shibuya-message-db-adapter/src/Shibuya/Adapter/MessageDb/Internal/Dlq.hs`:

```haskell
renderReason :: DeadLetterReason -> Text
renderReason = \case
    PoisonPill t -> "poison_pill:" <> t
    InvalidPayload t -> "invalid_payload:" <> t
    MaxRetriesExceeded -> "max_retries_exceeded"
```

It feeds the `deadLetterReason` key of `buildDlqMetadata` (lines 141 to 163 of the same file),
which builds the JSON metadata of the `$DeadLetter` message written to the dead-letter stream.
`Internal.hs` imports `DeadLetterReason (..)` at line 115 and uses `MaxRetriesExceeded` at line
301 to auto-dead-letter a message whose delivery count exceeds the configured maximum; that use
is unaffected.

The dependency bound for effectful is the one defined in
`docs/plans/34-harden-shibuya-core-dependency-bounds-and-release-gating-for-effectful-2-7.md`
and copied by every adapter: `effectful-core (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)` and
`effectful >=2.6.1 && <2.8`. Apply it here in the same change so this adapter is not the one
package left behind on the 2.6 family.

Precedent for the whole migration is in the shibuya repository's `docs/plans/13-…`, `14-…`,
and `15-…` (the 0.7 headers upgrade of the Kafka, pgmq, and kiroku adapters) and in the kiroku
repository's commit `6660200 feat(shibuya-kiroku-adapter): upgrade to shibuya-core 0.9.0.0`,
which mapped `ApplicationFailure` to a structured JSON object with `code` and `detail` keys.

No ADR exists for this repository or for shibuya; neither has a `docs/adr/` directory and Mori
lists no ADR bundle.


## Plan of Work

### Milestone 1: compile against shibuya-core 0.9

Raise the bounds and make the code compile. In the library cabal file set `shibuya-core
>=0.9.0.2 && <0.10` (or `>=0.9.0.1 && <0.10` only if plan 33's release is not yet published;
note which in the Decision Log), apply the effectful bound expression to lines 63 to 64, and add
`-Werror=incomplete-patterns` to the `common warnings` stanza with a comment explaining that
the adapter translates a dependency-owned sum type and must fail the build, not the first
message, when upstream adds a constructor. Mirror the `shibuya-core` bound in the jitsurei
cabal file and bump its `shibuya-message-db-adapter` bound to `^>=0.2.0.0`. Add `headers =
Nothing` to `messageToEnvelope`. Build; the compiler will now reject `renderReason` as
incomplete, which is the cue for Milestone 2, so temporarily satisfy it by routing every
constructor through the projections (the final form is specified in Milestone 2; implementing
it now is fine and Milestone 2 then only adds the new keys and tests).

At the end of this milestone `cabal build all` succeeds in the flake shell with no warnings
about incomplete patterns, and `cabal test` passes with PostgreSQL running.

### Milestone 2: structured dead-letter metadata

Replace `renderReason` with a projection-based renderer that preserves the legacy format and
add the two structured keys. In `Internal/Dlq.hs` change the import at line 49 to
`import Shibuya.Core.Ack (DeadLetterReason, deadLetterCodeText, deadLetterReasonCode,
deadLetterReasonDetail)` and define:

```haskell
-- | Legacy single-string form kept byte-for-byte for the built-in reasons:
-- @<code>:<detail>@ with no space, or @<code>@ alone when there is no detail.
renderReason :: DeadLetterReason -> Text
renderReason reason =
    let code = deadLetterCodeText (deadLetterReasonCode reason)
     in case deadLetterReasonDetail reason of
            Nothing -> code
            Just detail -> code <> ":" <> detail
```

In `buildDlqMetadata` add, after the `deadLetterReason` entry:

```haskell
            , (Key.fromText "deadLetterReasonCode", Aeson.String (deadLetterCodeText (deadLetterReasonCode reason)))
            , (Key.fromText "deadLetterReasonDetail", maybe Aeson.Null Aeson.String (deadLetterReasonDetail reason))
```

Update the Haddock above `buildDlqMetadata` (the field list at lines 121 to 140) to describe
both new keys and to say `deadLetterReasonDetail` is JSON `null` for `MaxRetriesExceeded`.

Add tests in `test/Shibuya/Adapter/MessageDb/DlqTest.hs` (the pure DLQ tests) asserting the
exact metadata for each of the four reasons, including that `PoisonPill "x"` still renders the
legacy string `poison_pill:x`, and add a database round-trip to
`test/Shibuya/Adapter/MessageDb/DeadLetterSkipAndLogTest.hs` that finalizes one message with
`AckDeadLetter (ApplicationFailure code "policy rejected")`, where `code` comes from
`mkDeadLetterCode "example.policy.rejected"`, and reads the `$DeadLetter` message back to
check `deadLetterReasonCode == "example.policy.rejected"`, `deadLetterReasonDetail == "policy
rejected"`, and `deadLetterReason == "example.policy.rejected:policy rejected"`.

At the end of this milestone the suite passes and the new assertions are in it.

### Milestone 3: examples, docs, release

Update `shibuya-message-db-adapter-jitsurei/app/DeadLetterDemo.hs` so one branch dead-letters
with `ApplicationFailure` (validate the code once at startup with `mkDeadLetterCode` and fail
loudly on `Left`), update `README.md`'s dead-letter section to list the three metadata keys,
add a `CHANGELOG.md` at the repository root (none exists) with a `0.2.0.0` section, set both
package versions to 0.2.0.0, format, run the suite one final time, commit, and tag `v0.2.0.0`.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/work/libraries/haskell/shibuya-message-db-adapter`
inside the flake shell (`nix develop`, or `direnv allow` once). Start the database in a second
terminal with `just process-up` and, the first time, `just bootstrap-message-db`.

Milestone 1:

```bash
cabal update
cabal build all
```

Expected on the first build after the bound change, before `headers` is added:

```text
src/Shibuya/Adapter/MessageDb/Convert.hs: error: [GHC-20125]
    • Constructor ‘Envelope’ does not have the required strict field(s): headers
```

After adding the field and before Milestone 2's renderer, with `-Werror=incomplete-patterns`:

```text
src/Shibuya/Adapter/MessageDb/Internal/Dlq.hs: error: [GHC-62161] [-Wincomplete-patterns, -Werror=incomplete-patterns]
    Pattern match(es) are non-exhaustive
    In a \case alternative: Patterns of type ‘DeadLetterReason’ not matched: ApplicationFailure _ _
```

That error is the evidence the flag works; replace the renderer and rebuild until clean, then:

```bash
cabal test
```

Expected: every test group reports `0 failures`.

Milestone 2: after adding the keys and tests,

```bash
cabal test --test-options='-m "dead-letter"'
cabal test
```

Expected: the focused run lists the new `ApplicationFailure` round-trip as passing, and the
full suite passes. To see the metadata directly, run the demo and query:

```bash
just seed-jitsurei-dlq
cabal run dead-letter-demo
psql -c "select metadata from message_store.messages where type = '\$DeadLetter' order by global_position desc limit 1;"
```

Expected: one row whose JSON contains `"deadLetterReasonCode"`, `"deadLetterReasonDetail"`,
and the unchanged `"deadLetterReason"`.

Milestone 3:

```bash
nix fmt
cabal build all && cabal test
git add -A && git commit
git tag -a v0.2.0.0 -m "shibuya-message-db-adapter 0.2.0.0"
```

The commit message follows Conventional Commits (for example `feat!: upgrade to shibuya-core
0.9 and store structured dead-letter reasons`) and carries the trailers
`MasterPlan: docs/masterplans/5-post-0-9-review-remediation-master-loop-removal-dependency-bound-hardening-and-adapter-parity.md`
and `ExecPlan: docs/plans/36-upgrade-shibuya-message-db-adapter-to-shibuya-core-0-9-and-structured-dead-letter-reasons.md`,
which name files in the shibuya repository where this plan lives. Push the branch and the tag
only when the maintainer says so.


## Validation and Acceptance

Milestone 1 is accepted when `cabal build all` is clean under `-Werror=incomplete-patterns`
against shibuya-core 0.9 and `cabal test` passes. Milestone 2 is accepted when the DLQ unit
tests pin all four reasons' metadata, the database round-trip for `ApplicationFailure` passes,
and a `psql` query of a dead-lettered demo message shows the three keys. Milestone 3 is
accepted when the suite passes on the tagged commit and `git tag -l v0.2.0.0` prints the tag.


## Idempotence and Recovery

All edits are source changes under git. The database used by tests is disposable: `just
drop-database` followed by `just bootstrap-message-db` recreates it, and the ephemeral-pg tests
create and destroy their own clusters. If the tag is created on the wrong commit before it is
pushed, `git tag -d v0.2.0.0` and re-tag; never move a pushed tag.


## Interfaces and Dependencies

Bounds at the end of Milestone 1, in `shibuya-message-db-adapter/shibuya-message-db-adapter.cabal`:

```text
shibuya-core     >=0.9.0.2 && <0.10
effectful        >=2.6.1 && <2.8
effectful-core   (>=2.6.1 && <2.7) || (>=2.7.1.1 && <2.8)
```

Functions used from shibuya-core, all in `Shibuya.Core.Ack`:

```haskell
deadLetterReasonCode   :: DeadLetterReason -> DeadLetterCode
deadLetterReasonDetail :: DeadLetterReason -> Maybe Text
deadLetterCodeText     :: DeadLetterCode -> Text
mkDeadLetterCode       :: Text -> Either Text DeadLetterCode
```

The adapter's own signature that must hold at the end of Milestone 2, in
`Shibuya.Adapter.MessageDb.Internal.Dlq`:

```haskell
renderReason     :: DeadLetterReason -> Text
buildDlqMetadata :: Mdb.Message -> DeadLetterReason -> UTCTime -> Mdb.MessageMetadata
```

with `buildDlqMetadata` producing the keys `correlation`, `causation`, `originalStream`,
`deadLetterReason`, `deadLetterReasonCode`, `deadLetterReasonDetail`, and `deadLetteredAt`.


## Revision Notes

2026-09-20 UTC: Replaced the provisional 0.9.1.0 dependency target with the selected
shibuya-core 0.9.0.2 patch release and recorded why this adapter need not wait for the later
dependency-bound hardening release.
