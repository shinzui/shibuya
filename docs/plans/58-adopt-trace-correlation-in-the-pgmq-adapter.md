---
id: 58
slug: adopt-trace-correlation-in-the-pgmq-adapter
title: "Adopt trace correlation in the PGMQ adapter"
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
---

# Adopt trace correlation in the PGMQ adapter

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

After this plan, the PGMQ adapter compiles against `shibuya-core` 0.13, defaults to
`ParentAndLink`, and lets a user choose `LinkOnly` with one configuration field. For PGMQ,
`LinkOnly` matters for delayed messages and for messages retried over long visibility timeouts,
where every redelivery otherwise lands in a producer trace that ended long ago. The plan also
establishes and tests what the dead-letter path does under `LinkOnly`, because that path writes
trace headers onto the dead-lettered message.

This plan lives in the Shibuya repository but is implemented in the PGMQ adapter repository,
`mori://shinzui/shibuya-pgmq-adapter`. It is the first adapter-level check of `LinkOnly` in the
parent MasterPlan, because this adapter's tests already run against a real PostgreSQL and assert
on trace headers.


## Progress

- [ ] M1: The adapter builds against `shibuya-core` 0.13 from Hackage with
  `PgmqAdapterConfig.traceCorrelation` defaulting to `ParentAndLink` and copied into the
  `Adapter`; configuration tests cover the default and the override; the full suite passes.
- [ ] M2: Tests show the span shape for both settings, the shape across redeliveries, and the
  dead-letter headers under `LinkOnly`; adapter benchmarks show no regression.
- [ ] M3: Documentation, changelog, example and version are updated; parent MasterPlan updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: PGMQ defaults to `ParentAndLink`.
  Rationale: PGMQ is a job queue: a message is consumed once, usually soon after it is sent, and
  users expect the job in the request's trace. Delayed sends and long retry cycles are the cases
  for opting into `LinkOnly`. This is a deliberate departure from the OpenTelemetry messaging
  conventions, which permit the creation context as parent for single messages but say it is
  "NOT RECOMMENDED ... (by default)" and require the choice to be documented; the capability
  document and README must say so.
  Date: 2026-11-11

- Decision: The dead-letter header merge is not changed.
  Rationale: It already writes the consumer span's context as the active `traceparent` and
  preserves the producer's under `x-shibuya-upstream-traceparent`. Under `LinkOnly` the active
  value names the consumer's own trace and the producer remains reachable through the preserved
  header and through the consumer span's link. That is coherent; it needs a test and a
  documented explanation, not new behaviour.
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

Find the adapter repository on disk with:

```bash
mori registry show shinzui/shibuya-pgmq-adapter --full
```

All paths below are relative to that repository's root. Packages: `shibuya-pgmq-adapter`
(library, test suite `shibuya-pgmq-adapter-test`), `shibuya-pgmq-adapter-bench` (benchmarks
`shibuya-pgmq-adapter-bench` and `dlq-payload-bench`, executables `endurance-test`,
`dlq-performance`, `dlq-admin-performance`), and `shibuya-pgmq-example` (executables
`shibuya-pgmq-simulator` and `shibuya-pgmq-consumer`, with `src/Example/Telemetry.hs`). Read the
repository's `CLAUDE.md` and `Justfile` for how PostgreSQL is provisioned for tests.

What `shibuya-core` 0.13 changed. The adapter interface gained a strict field:

```haskell
-- Shibuya.Adapter
data Adapter es msg = Adapter
  { adapterName :: !Text,
    source :: Stream (Eff es) (Ingested es msg),
    shutdown :: Eff es (),
    traceCorrelation :: !TraceCorrelation
  }

-- Shibuya.Telemetry.Correlation, re-exported from Shibuya.Adapter
data TraceCorrelation = ParentAndLink | LinkOnly
```

The framework creates the processing span. It reads `traceCorrelation` once per processor; for
each message with `Envelope.traceContext` it always adds a link to that context and makes it
the parent only under `ParentAndLink`. Under `LinkOnly` the span is a root in a new trace.
`Shibuya.Telemetry.Propagation.currentTraceHeaders`, called inside a handler or an
acknowledgement, returns the headers of the *currently active span*, which is the processing
span; under `LinkOnly` those headers therefore name the new trace. Batch spans always link all
members and take no parent, whatever the setting. If the published API differs, follow it and
record the difference.

The same `shibuya-core` release renames the processing span from `<destination> process` to
`process <destination>` and adds the attribute `messaging.operation.name = "process"`. Search
this repository for the old form (`grep -rn ' process"\|process`' --include='*.hs' --include='*.md' .`)
and update every test, example and document that matches it; note the rename in the changelog.
One occurrence is known: `shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/ChaosSpec.hs` selects
spans named `"dlq-identity process"`, which becomes `"process dlq-identity"`.

Where the adapter stands today.
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Config.hs` defines `PgmqAdapterConfig` (with
nested `PollingConfig`, `PrefetchConfig`, `DeadLetterConfig`, `FifoConfig`), a validation error
type `PgmqConfigError`, and `defaultConfig :: QueueName -> PgmqAdapterConfig`.
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs` constructs the `Adapter` (near
`adapterName = "pgmq:" <> …`).
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` fills `Envelope.traceContext` from
the message's JSONB `headers` (`extractTraceHeaders`) and sets `Envelope.attempt` from pgmq's
read count; this plan does not change it.
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs` has
`mergeDlqHeaders :: Maybe TraceHeaders -> Maybe Value -> Maybe Value`: when a message is
dead-lettered and a consumer span is active, the consumer's `traceparent`/`tracestate` take the
active header slots on the dead-letter message and the original producer values are moved to
`x-shibuya-upstream-traceparent` / `x-shibuya-upstream-tracestate`; with no consumer span the
original headers pass through unchanged. Tests are under
`shibuya-pgmq-adapter/test/Shibuya/Adapter/Pgmq/`: `ConfigSpec.hs`, `ConvertSpec.hs`,
`InternalSpec.hs` (unit tests of `mergeDlqHeaders`), `DeadLetterSpec.hs`, `IntegrationSpec.hs`,
`ChaosSpec.hs` (dead-letter trace headers end to end against PostgreSQL). The library version is
0.18.0.0 and every cabal stanza pins `shibuya-core ^>=0.12.0.0`.

Documents: `docs/capabilities/otel-trace-propagation.md` (a profile-governed capability bundle;
keep its frontmatter valid) currently says the handler "runs in the producer's trace";
`docs/pgmq-adapter/ARCHITECTURE.md`, `docs/pgmq-adapter/INTERNALS.md`, `README.md` and
`docs/user/` describe tracing. Decision records under `docs/adr/` are plain Markdown;
the two existing ones (idempotent dead-letter moves, managed DLQ administration) are not
changed by this plan. The Shibuya-side decision is in the Shibuya repository's correlation ADR
(created by Shibuya plan 55); cite it by the canonical URI returned by
`mori registry concepts --search 'trace correlation' --json`, or, if not listed, as
`mori://shinzui/shibuya` plus its path under `docs/adr/`, noting the artifact URI is pending.

Performance and space. The adapter change is one strict enumeration field set at construction.
`Convert.hs` and the dead-letter path are untouched, so no per-message work is added in this
repository. The obligation is to confirm the adapter's benchmarks are unchanged after the
dependency bump and that both new fields are strict.


## Plan of Work

### Milestone 1: compile against 0.13 and expose the setting

Raise the `shibuya-core` bound to `^>=0.13.0.0` in every stanza that names it (two in
`shibuya-pgmq-adapter.cabal`, five in `shibuya-pgmq-adapter-bench.cabal`, one in
`shibuya-pgmq-example.cabal`), after verifying the published version.

Add `traceCorrelation :: !TraceCorrelation` to `PgmqAdapterConfig` with a Haddock comment giving
the default and the cases for `LinkOnly`; set `ParentAndLink` in `defaultConfig`. The field
needs no validation. Re-export `TraceCorrelation (..)` from `Shibuya.Adapter.Pgmq`. Set the
`Adapter`'s `traceCorrelation` from the validated config in `Pgmq.hs`. Fix every other record
literal the compiler reports.

Extend `ConfigSpec.hs`: the default is `ParentAndLink`; a config with `LinkOnly` validates and
the resulting adapter exposes `LinkOnly`.

### Milestone 2: prove the behaviour

Add tests using tracing enabled with an in-memory span exporter
(`hs-opentelemetry-exporter-in-memory`), in `IntegrationSpec.hs` or a new
`CorrelationSpec.hs` beside it, against the test PostgreSQL:

- A message sent with a known `traceparent` and processed under the default: the processing
  span has the producer's trace ID, the producer as parent, and one link to it.
- The same under `LinkOnly`: a different trace ID, no parent, the same link.
- Redelivery under `LinkOnly`: a handler that returns a retry on the first delivery and succeeds
  on the second produces two processing spans in two different traces, each with a link to the
  same producer span. Under the default the two spans share the producer's trace. This is the
  behaviour to document for retries.
- Dead-letter under `LinkOnly` (extend `ChaosSpec.hs` or `DeadLetterSpec.hs`): after the handler
  dead-letters the message, the dead-letter queue message's `traceparent` carries the consumer
  processing span's trace ID and span ID, which differ from the producer's, and
  `x-shibuya-upstream-traceparent` equals the original producer header byte for byte.
- Dead-letter under the default: unchanged from today (the existing assertions keep passing).

This is the representative adapter-level check named in the parent MasterPlan. If the link-only
dead-letter test reveals that the consumer context is absent or wrong at the point
`mergeDlqHeaders` is called, stop and record it in the MasterPlan's Surprises & Discoveries
before the Kafka and Kiroku plans finalise their documentation, because it would indicate a
defect in `shibuya-core`'s context handling rather than in this adapter.

Run the benchmarks against a baseline from the previous release tag as in Concrete Steps.
Expected: no time change beyond noise and no allocation change in cells with tracing disabled.
A cell with tracing enabled and headers present may show one link's worth of allocation per
message; record its size. Explain anything else before continuing. If time permits, run
`endurance-test` for its usual duration and confirm resident memory is flat as in previous
runs recorded under `docs/performance/`; treat growth as a blocker.

### Milestone 3: documentation, example and version

Rewrite the "On ingest" bullet in `docs/capabilities/otel-trace-propagation.md`: the handler
runs in the producer's trace by default and in its own linked trace under `LinkOnly`, noting
that the OpenTelemetry messaging conventions recommend link-only as the default and this adapter
deliberately keeps the parent for continuity; add a
bullet describing the dead-letter headers under each setting and the redelivery shape; keep the
frontmatter valid, add the new tests as evidence entries, and run the bundle's validation as the
repository's instructions describe. Update `README.md`, the user documentation under
`docs/user/`, and `docs/pgmq-adapter/ARCHITECTURE.md` where they describe trace propagation.
Let `shibuya-pgmq-example`'s consumer choose the policy from its configuration
(`src/Example/Config.hs`) so both shapes can be shown.

Add a changelog entry to `shibuya-pgmq-adapter/CHANGELOG.md` and the root `CHANGELOG.md`.
Adding a field to an exported record is breaking under the PVP; bump the major version
following the repository's release skill.

In the Shibuya repository, mark this plan Complete in the MasterPlan registry, update Progress,
and record the outcome of the representative check.


## Concrete Steps

In the adapter repository root, inside its nix devShell, with the test PostgreSQL started as the
repository's `CLAUDE.md` describes:

```bash
cabal update
cabal build all
cabal test shibuya-pgmq-adapter
nix fmt
```

Benchmark comparison, where `<last-tag>` is the previous release tag:

```bash
git worktree add /tmp/pgmq-adapter-baseline <last-tag>
( cd /tmp/pgmq-adapter-baseline && \
  cabal bench shibuya-pgmq-adapter-bench \
    --benchmark-options="--stdev 5 --timeout 120 --csv /tmp/pgmq-adapter-baseline.csv" )
cabal bench shibuya-pgmq-adapter-bench \
  --benchmark-options="--stdev 5 --timeout 120 --baseline /tmp/pgmq-adapter-baseline.csv --fail-if-slower 10"
git worktree remove /tmp/pgmq-adapter-baseline
```

If the benchmark needs a database or different options, follow
`shibuya-pgmq-adapter-bench`'s README and record the command used.

Expected test output includes lines such as:

```text
Correlation
  ParentAndLink: process span is a child of the producer with one link
  LinkOnly: process span is a linked root
  LinkOnly: each redelivery is its own linked trace
  LinkOnly: DLQ traceparent is the consumer's, upstream preserved
```

Commit messages in the adapter repository follow Conventional Commits and carry:

```text
MasterPlan: mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans
ExecPlan: mori://shinzui/shibuya/plans/58-adopt-trace-correlation-in-the-pgmq-adapter
Intention: intention_01m76tvgq9epqr5p2vdekeetxe
```


## Validation and Acceptance

The adapter builds and its whole test suite passes against `shibuya-core` 0.13 from Hackage,
with no Shibuya source override left in `cabal.project`.

`defaultConfig q` has `traceCorrelation == ParentAndLink`. The five behaviours in Milestone 2
are each demonstrated by a passing test; the dead-letter test under `LinkOnly` would fail if the
upstream header were lost or if the active header still named the producer.

The benchmark comparison exits 0 with no unexplained allocation increase.

The capability document no longer claims the handler always runs in the producer's trace, and
its validation passes.


## Idempotence and Recovery

All edits are repeatable. Tests create and drop their own queues; if a run is interrupted,
re-running recreates them (see the repository's database recipes for a full reset). If Hackage
lacks 0.13, keep the plan In Progress on the temporary pin rather than loosening bounds. Remove
worktrees after use.


## Interfaces and Dependencies

Prerequisite from the parent MasterPlan: Shibuya plan 55 Complete and the release gate passed
(`shibuya-core` 0.13.0.0 on Hackage). Shibuya plan 56 (batch links) is a soft dependency
affecting documentation only.

Consumes from `shibuya-core` `^>=0.13.0.0`: `Shibuya.Adapter.Adapter` with `traceCorrelation`,
`Shibuya.Adapter.TraceCorrelation (..)`, and the unchanged
`Shibuya.Telemetry.Propagation.currentTraceHeaders`.

Provides:

```haskell
-- Shibuya.Adapter.Pgmq.Config
data PgmqAdapterConfig = PgmqAdapterConfig
  { ...,
    traceCorrelation :: !TraceCorrelation  -- default ParentAndLink
  }
```

`mergeDlqHeaders` keeps its signature and behaviour. No other plan depends on this one, but its
link-only dead-letter test is the representative check the Kafka plan (57) and Kiroku plan (59)
rely on for their documentation of `LinkOnly`.
