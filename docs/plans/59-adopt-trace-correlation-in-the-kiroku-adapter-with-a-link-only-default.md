---
id: 59
slug: adopt-trace-correlation-in-the-kiroku-adapter-with-a-link-only-default
title: "Adopt trace correlation in the Kiroku adapter with a link-only default"
kind: exec-plan
created_at: 2026-11-12T02:55:43Z
intention: "intention_01m76tvgq9epqr5p2vdekeetxe"
master_plan: "docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md"
provenance:
  created_by:
    model: "claude-fable-5-2"
    harness: "claude-code"
    at: 2026-11-12T02:55:43Z
  revisions:
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-12T03:14:10Z
      mode: "update"
      note: "Align with full reading of OTel messaging spans spec; record deviations"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-12T03:25:31Z
      mode: "update"
      note: "Add EP-7 span rename and messaging.operation.name"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-12T03:38:50Z
      mode: "update"
      note: "Carry the policy in an extensible AdapterTelemetry record"
    - model: "claude-fable-5-2"
      harness: "claude-code"
      at: 2026-11-12T03:50:42Z
      mode: "update"
      note: "Record that kiroku-otel subscription spans are independent roots"
---

# Adopt trace correlation in the Kiroku adapter with a link-only default

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

`shibuya-core` 0.13 lets each queue adapter declare how the tracing span around a message's
processing relates to the span that produced the message: `ParentAndLink` (the processing span
is a child of the producer's span and also carries a *link* to it, giving one connected trace)
or `LinkOnly` (the processing span starts a new trace and is related to the producer only by
the link, which is OpenTelemetry's pointer between causally related spans in different traces).

Kiroku is an event store. The Shibuya adapter for it delivers recorded events from a
subscription, and a subscription differs from a queue in exactly the ways that make parenthood
wrong: it replays history from a checkpoint, so an event may be processed months after the
trace that wrote it ended; it catches up in bulk; and several independent subscriptions and
consumer-group members read the same event. Making each of those processing spans a child of
the original append span attaches unbounded late work to a finished trace.

After this plan, the Kiroku adapter compiles against `shibuya-core` 0.13 and defaults to
`LinkOnly`: each event's processing span is its own trace, linked to the span that appended the
event. A user who wants the previous single-trace shape sets one configuration field to
`ParentAndLink`. This is a change of default behaviour for existing users and is released and
documented as such.

This plan lives in the Shibuya repository but is implemented in the Kiroku repository,
`mori://shinzui/kiroku`, in its package `shibuya-kiroku-adapter`.


## Progress

- [ ] M1: The finding that `kiroku-otel`'s subscription spans are independent roots (see the
  Decision Log) is re-confirmed against the current code, so the `LinkOnly` default stands.
- [ ] M2: The adapter builds against `shibuya-core` 0.13 with `telemetry` on
  `KirokuAdapterConfig` (default `LinkOnly`), honoured by single adapters and by every
  consumer-group member; tests cover the default, the override, and the span shape.
- [ ] M3: Performance checks show no regression; documentation, changelog, decision record and
  version are updated; the parent MasterPlan is updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Kiroku defaults to `LinkOnly`, subject to confirmation in Milestone 1.
  Rationale: Replay from a checkpoint, bulk catch-up, and fan-out to several subscribers are the
  normal operating mode of an event-store subscription, and each makes joining the writer's
  trace harmful. This is also the default the OpenTelemetry messaging conventions recommend:
  every processing span "SHOULD link to the message's creation context", and using that context
  as parent is "NOT RECOMMENDED ... (by default)". The Kafka and PGMQ adapters deliberately keep
  the parent by default; Kiroku does not, so the documentation must explain why the adapters
  differ.
  Date: 2026-11-11

- Decision: `kiroku-otel`'s native subscription spans are left as they are; there is no
  conflict to fix.
  Rationale: Read on 2026-11-11 in `kiroku-otel/src/Kiroku/Otel/Subscription.hs`: every native
  span (`kiroku.subscription.catchup`, `.deliver`, `.paused`, `.reconnecting`, `.retrying`,
  `.dead_letter`, `.db_error`, `.stopped`) is created with
  `createSpan tracer Context.empty …`, so each is a root in its own trace. They describe the
  subscription worker's lifecycle, are driven from the store's event callback, and are neither
  children of nor linked to the span that appended an event, nor parents of Shibuya's
  processing span. The two instrumentations are complementary: native spans answer "what is the
  worker doing", Shibuya's answer "what happened to this event". They are correlated by shared
  `kiroku.*` attribute values, which is what the adapter changelog's "a single trace is
  followable" refers to; that wording overstates it, since they have never shared a trace.
  `LinkOnly` therefore breaks no existing nesting. Milestone 1 re-confirms this against the
  code at implementation time.
  Date: 2026-11-11

- Decision: A per-event policy (parent when live, link when catching up) is not part of this
  plan.
  Rationale: The adapter receives no signal saying which phase delivered an event. That signal
  is requested from Kiroku in
  `mori://shinzui/kiroku/okf/improvement-requests/concepts/IR-21`; until it exists the policy
  stays one value per adapter.
  Date: 2026-11-11

- Decision: The setting applies uniformly to a consumer group; members do not differ.
  Rationale: A consumer group is one logical subscription presented as several processors. A
  per-member policy has no use and would complicate `KirokuConsumerGroupConfig`.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This is a child of the Shibuya MasterPlan
`mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`
(file `docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md` in the Shibuya
repository). Prerequisite: `shibuya-core` 0.13.0.0 is published on Hackage. Confirm with
`cabal update && cabal info shibuya-core | head` and against Hackage itself. If it is not
published, development can use a temporary `source-repository-package` entry for the Shibuya
repository in `cabal.project`, but this plan is not complete until that entry is removed.

Find the Kiroku repository on disk with:

```bash
mori registry show shinzui/kiroku --full
```

All paths below are relative to that repository's root. Read its `CLAUDE.md` first. The
relevant packages are `shibuya-kiroku-adapter` (library, test suite
`shibuya-kiroku-adapter-test` in `test/Main.hs`, executable `lifecycle-live`, benchmark
`kiroku-mp12-write-probe`), `kiroku-otel` (OpenTelemetry helpers for Kiroku itself), and
`kiroku-store` (which also depends on `shibuya-core`; its bound must move with the adapter's).
`cabal.project` pins the compiler and lists the packages.

What `shibuya-core` 0.13 changed. The adapter interface gained a strict field:

```haskell
-- Shibuya.Adapter
data Adapter es msg = Adapter
  { adapterName :: !Text,
    source :: Stream (Eff es) (Ingested es msg),
    shutdown :: Eff es (),
    telemetry :: !AdapterTelemetry
  }

-- Shibuya.Telemetry.Correlation, re-exported from Shibuya.Adapter
data TraceCorrelation = ParentAndLink | LinkOnly

data AdapterTelemetry = AdapterTelemetry { traceCorrelation :: !TraceCorrelation }

defaultAdapterTelemetry :: AdapterTelemetry  -- traceCorrelation = ParentAndLink
```

`AdapterTelemetry` is exported without its constructor: obtain a value from
`defaultAdapterTelemetry` and change it with record update, for example
`defaultAdapterTelemetry {traceCorrelation = LinkOnly}`. It exists so that `shibuya-core` can
add telemetry options later without another breaking change to `Adapter`. For the same reason
this adapter's configuration carries the whole `AdapterTelemetry` value in a field named
`telemetry` and copies it into `Adapter` unchanged, rather than exposing only the policy.
Wherever this plan speaks of the adapter's default or of setting the policy, it means the
`traceCorrelation` field of that `telemetry` value. Re-export `AdapterTelemetry`, its field and
`defaultAdapterTelemetry` from the adapter's top-level module along with `TraceCorrelation (..)`.
If the published 0.13 offers a setter function instead of record update, use that.

The framework creates the processing span. It reads `telemetry.traceCorrelation` once per processor; for
each message whose `Envelope.traceContext` holds W3C `traceparent`/`tracestate` header pairs it
always adds a link to that context, and makes it the parent only under `ParentAndLink`. Under
`LinkOnly` the span is a root in a new trace. Batch spans always link all members and take no
parent, whatever the setting. If the published API differs, follow it and record the
difference.

The same `shibuya-core` release renames the processing span from `<destination> process` to
`process <destination>` and adds the attribute `messaging.operation.name = "process"`. Search
this repository for the old form (`grep -rn ' process"\|process`' --include='*.hs' --include='*.md' .`)
and update every test, example and document that matches it; note the rename in the changelog.

Where the adapter stands today. `shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku.hs` defines
`KirokuAdapterConfig` (fields include `subscriptionName`, `subscriptionTarget`, `batchSize`),
`defaultKirokuAdapterConfig`, the single-adapter constructor that builds
`Adapter { adapterName = "kiroku", source = …, shutdown = … }`, and the consumer-group API:
`KirokuConsumerGroupConfig`, `defaultConsumerGroupConfig`, and
`kirokuConsumerGroupProcessorsWith`, which builds one adapter per group member through a
`mkMemberAdapter :: Int32 -> Eff es (Adapter es RecordedEvent)` function.
`shibuya-kiroku-adapter/src/Shibuya/Adapter/Kiroku/Convert.hs` fills `Envelope.traceContext`
from the recorded event's JSON `metadata` (`metadataTraceContext` reads a string `traceparent`
and optional `tracestate`); this plan does not change it. The adapter's tests currently run
under `runTracingNoop` only. The adapter version is 0.7.0.1 and its cabal stanzas, and
`kiroku-store/kiroku-store.cabal`, bound `shibuya-core >=0.12 && <0.13`.

`kiroku-otel` matters here. `kiroku-otel/src/Kiroku/Otel/TraceContext.hs` writes a span's
context into an event's metadata on append (`injectTraceContext`) and reads it back
(`extractTraceContext`); that is where the `traceparent` the adapter sees comes from.
`kiroku-otel/src/Kiroku/Otel/Subscription.hs` produces Kiroku's *own* subscription spans from
its event hooks, independently of Shibuya. The adapter's changelog
(`shibuya-kiroku-adapter/CHANGELOG.md`) contains a statement that, together with
`kiroku-otel`'s native subscription spans, "a single trace is followable". Changing the default
to `LinkOnly` alters what that sentence promises, so the first milestone is to read these two
modules and the capability documents `docs/capabilities/opentelemetry-subscription-tracing.md`
and `docs/capabilities/opentelemetry-trace-context.md` and establish how Kiroku's own
subscription spans relate to the appending span today.

Decision records in Kiroku live in `docs/adr/` as a *profile-governed* bundle
(`docs/adr/profile.dhall`, declared in `mori.dhall`): each record has frontmatter with a stable
`docId` of the form `ADR-N`, allocated with `okf id next`, and the bundle is validated with
`okf validate … --strict --profile-enforce`. Follow that repository's
`agents/skills/exec-plan/ADR.md` exactly when adding one. Existing ADR
`docs/adr/0002-static-hash-partitioned-consumer-groups.md` describes consumer groups and
`docs/adr/0005-three-tier-performance-regression-gates.md` describes that repository's
performance gates; read both. The Shibuya-side decision is in the Shibuya repository's
correlation ADR (created by Shibuya plan 55); cite it by the canonical URI returned by
`mori registry concepts --search 'trace correlation' --json`, or, if not listed, as
`mori://shinzui/shibuya` plus its path under `docs/adr/`, noting the artifact URI is pending.

Performance and space. The adapter change is one strict enumeration field set at construction
and threaded to each member adapter; nothing is added per event and `Convert.hs` is unchanged.
The cost of the link was gated in `shibuya-core`. Two things are specific to Kiroku and must be
checked here: catch-up delivers events in bulk at high rate, so heap residency during a long
catch-up with tracing enabled must be flat; and Kiroku's own performance gates (ADR 0005 in
that repository) must still pass after the dependency bump.


## Plan of Work

### Milestone 1: understand Kiroku's own subscription spans and confirm the default

Read `kiroku-otel/src/Kiroku/Otel/Subscription.hs` and the two capability documents. Determine
whether Kiroku's native subscription spans are children of the appending span, link to it, or
are unrelated to it, and whether the adapter's processing span is expected to nest under a
native subscription span or sit beside it.

Decide by this rule and record the outcome in the Decision Log. If the native spans already
link to the appending span or are unrelated roots, `LinkOnly` for the adapter is consistent:
proceed. If the native spans are children of the appending span, the two layers would disagree
under `LinkOnly`; then keep `LinkOnly` as the adapter default (the reasoning in Purpose still
holds), document the difference clearly, and file an improvement request in the Kiroku
repository's `docs/improvement-requests/` bundle proposing the same policy for `kiroku-otel`,
rather than widening this plan to change `kiroku-otel`. If reading shows the adapter's span is
designed to be a child of a native subscription span through the ambient context (not through
event metadata), stop and raise it in the parent MasterPlan, because `LinkOnly` clears the
ambient context and would break that nesting.

### Milestone 2: compile against 0.13, expose the setting, test it

Raise the `shibuya-core` bound to `>=0.13 && <0.14` in the four stanzas of
`shibuya-kiroku-adapter/shibuya-kiroku-adapter.cabal` and in `kiroku-store/kiroku-store.cabal`,
after verifying the published version. Fix any `Adapter { … }` literal the compiler reports
anywhere in the repository (search with `grep -rn "Adapter$\|Adapter {" --include='*.hs' .`).

Add `telemetry :: !AdapterTelemetry` to `KirokuAdapterConfig` with a Haddock comment that
states the default, why it differs from queue adapters, and how to restore the single-trace
shape; set it to `defaultAdapterTelemetry {traceCorrelation = LinkOnly}` in
`defaultKirokuAdapterConfig`. Set the `Adapter`'s field from the
config where the adapter is constructed. Make sure every path that builds a member adapter for
a consumer group uses the same value: trace how `kirokuConsumerGroupProcessorsWith` and its
callers obtain `mkMemberAdapter`, and add the field to `KirokuConsumerGroupConfig` only if the
group path does not already go through `KirokuAdapterConfig`. Re-export `TraceCorrelation (..)`
from `Shibuya.Adapter.Kiroku`.

Add tests to `shibuya-kiroku-adapter/test/Main.hs` (or a new module beside it, registered in the
cabal file), using tracing enabled with the in-memory span exporter
(`hs-opentelemetry-exporter-in-memory`; add it to the test stanza):

- the default config has `LinkOnly`; a config overridden to `ParentAndLink` yields an adapter
  exposing `ParentAndLink`;
- an event appended with a known `traceparent` in its metadata and delivered under the default
  yields a processing span with a trace ID different from the writer's, no parent, and one link
  to the writer's span;
- the same under `ParentAndLink` yields the writer's trace ID, the writer as parent, and the
  link;
- the same event delivered to two different subscriptions under the default yields two
  processing spans in two different traces, both linking to the one writer span;
- every member of a consumer group reports the configured policy;
- an event without `traceparent` in its metadata yields a span with no link under either policy.

### Milestone 3: performance, documentation, decision record, version

Run that repository's performance gates as its ADR 0005 and benchmark documents
(`docs/BENCH-REGRESSION.md`) describe, before and after the change, and require no regression.
In addition, run a catch-up with tracing enabled over a large pre-populated stream (reuse the
`lifecycle-live` executable or the test support package to append at least 200,000 small events
carrying `traceparent` metadata, then start a subscription from the beginning with a tracer
whose provider has no span processors) and sample live heap bytes after major collections at
20,000 and 200,000 processed events (`GHC.Stats`, run with `+RTS -T`). The second sample must
not be materially larger than the first. Record the numbers in this plan. Growth is a blocker:
investigate whether it is in the adapter, in `shibuya-core` (report it to the parent
MasterPlan), or in the measurement.

Update `shibuya-kiroku-adapter/CHANGELOG.md` with a clearly marked behaviour change: the
default trace shape is now one linked trace per processed event; give the one-line way to
restore the previous shape; and correct the earlier "a single trace is followable"
statement to say that native subscription spans and Shibuya's processing spans are separate
traces correlated by matching `kiroku.*` attributes. Adding a record field and changing default behaviour is a breaking change; bump the
major version following that repository's release process. Update the adapter's Haddock module
header and the capability documents `docs/capabilities/opentelemetry-trace-context.md` and
`docs/capabilities/opentelemetry-subscription-tracing.md` where they describe how consumer
spans relate to append spans, keeping frontmatter valid and running the bundle validation.

Add an ADR to Kiroku's `docs/adr/` bundle recording that the Shibuya adapter correlates
processing to appends by link by default, with the reasons specific to an event store, the
override, and the relationship to `kiroku-otel`'s native spans found in Milestone 1. Allocate
its handle with `okf id next`, add the log entry with `okf log add`, and run strict validation,
as that repository's ADR guide requires. Cite the Shibuya ADR by its canonical URI.

In the Shibuya repository, mark this plan Complete in the MasterPlan registry and update
Progress.


## Concrete Steps

In the Kiroku repository root, inside its nix devShell, with its test database running as its
`CLAUDE.md` describes:

```bash
cabal update
cabal build all
cabal test shibuya-kiroku-adapter
cabal test kiroku-store
nix fmt
```

Decision-record tooling:

```bash
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Expected new test output includes lines such as:

```text
trace correlation
  default is LinkOnly
  LinkOnly: processing span is a linked root
  ParentAndLink: processing span is a child of the append span with one link
  two subscriptions: two traces, one linked append span
  consumer group members share the policy
```

Commit messages in the Kiroku repository follow Conventional Commits and carry:

```text
MasterPlan: mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans
ExecPlan: mori://shinzui/shibuya/plans/59-adopt-trace-correlation-in-the-kiroku-adapter-with-a-link-only-default
Intention: intention_01m76tvgq9epqr5p2vdekeetxe
```


## Validation and Acceptance

Milestone 1's finding about `kiroku-otel`'s native subscription spans is written in the Decision
Log with the file and function it was read from.

The repository builds and the adapter's and store's test suites pass against `shibuya-core`
0.13 from Hackage, with no Shibuya source override left in `cabal.project`.

`defaultKirokuAdapterConfig` yields `LinkOnly`. The six test cases in Milestone 2 pass; before
this plan the linked-root case cannot pass because the span is always a child and has no link.

Kiroku's performance gates pass, and the catch-up heap samples at 20,000 and 200,000 events are
recorded and flat.

The changelog states the behaviour change and how to revert it. The new ADR passes strict
validation.


## Idempotence and Recovery

Source edits are repeatable and reversible with git. Tests manage their own database state; a
full reset uses the repository's database recipes. If Hackage lacks 0.13, keep the plan In
Progress on the temporary pin. If `okf id next` was run but the ADR was not committed, run
`okf id list` again before allocating so a handle is not skipped or reused. The catch-up
measurement writes many events to a scratch database; use a dedicated database or schema and
drop it afterwards.


## Interfaces and Dependencies

Prerequisite from the parent MasterPlan: Shibuya plan 55 Complete and the release gate passed
(`shibuya-core` 0.13.0.0 on Hackage). Shibuya plan 56 (batch links) is a soft dependency
affecting documentation only. The PGMQ plan (Shibuya plan 58) runs the first adapter-level
`LinkOnly` check; if it reported a defect in the parent MasterPlan's Surprises & Discoveries,
read that before starting.

Consumes from `shibuya-core` `>=0.13 && <0.14`: `Shibuya.Adapter.Adapter` with
`telemetry`, `Shibuya.Adapter.AdapterTelemetry` with `defaultAdapterTelemetry`, and
`Shibuya.Adapter.TraceCorrelation (..)`.

Provides:

```haskell
-- Shibuya.Adapter.Kiroku
data KirokuAdapterConfig = KirokuAdapterConfig
  { ...,
    telemetry :: !AdapterTelemetry  -- default: traceCorrelation = LinkOnly
  }
```

`Shibuya.Adapter.Kiroku.Convert` and `kiroku-otel` are not changed. No other plan depends on
this one.
