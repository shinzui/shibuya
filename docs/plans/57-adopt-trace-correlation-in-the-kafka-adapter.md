---
id: 57
slug: adopt-trace-correlation-in-the-kafka-adapter
title: "Adopt trace correlation in the Kafka adapter"
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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:51:06Z
      mode: "update"
      note: "Resolve review contracts and sequencing; retain benchmark scope and external verification limits."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-13T17:49:52Z
      mode: "implement"
      note: "Implement adapter adoption: 0.13 bound, telemetry field, correlation tests, docs"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:42:29Z
      verdict: "changes-requested"
      note: "Align release start prerequisite and PGMQ check ordering; adapter source verification unavailable."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:51:07Z
      verdict: "comments"
      note: "Follow-up: planning findings resolved; document checks pass; dependency, adapter and runtime validation remain implementation prerequisites."
---

# Adopt trace correlation in the Kafka adapter

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

After this plan, the Kafka adapter compiles against `shibuya-core` 0.13, defaults to
`ParentAndLink`, and lets a user choose `LinkOnly` with one configuration field. `LinkOnly`
matters for Kafka when a consumer group replays a topic from an old offset, lags far behind, or
is one of many groups reading the same topic: in those cases joining the producer's trace
stretches or overloads it. A user can see the difference by running the adapter's OpenTelemetry
demo against the local Jaeger and comparing the two settings.

This plan lives in the Shibuya repository but is implemented in the Kafka adapter repository,
`mori://shinzui/shibuya-kafka-adapter`.


## Progress

- [x] M1 (2026-11-13): builds against `shibuya-core` 0.13.0.1 from Hackage (all five stanzas
  `^>=0.13.0.0`, no source override); `KafkaAdapterConfig.telemetry` defaults to
  `defaultAdapterTelemetry` and reaches the `Adapter`; unit tests cover the default and the
  override. Full suite against the private broker (127.0.0.1:29092): 78 tests pass, including
  the 15 broker-backed integration tests. Kafka commits `fee5690`, `05accc5`.
- [x] M2 (2026-11-13): broker-free `CorrelationTest` over the scripted log proves both span shapes
  through `kafkaAdapter` and the runner with an in-memory exporter. The benchmark (`v0.12.0.0` vs
  `fee5690` in clean worktrees, three interleaved pairs at `--stdev 3`) shows identical
  allocation in all 16 cells and median time ratio 0.991 (0.946–1.026). In the trace backend,
  `otel-producer-demo` then `otel-demo` (two records: the upstream-instrumented `send orders` and
  the DIY `shibuya.send.message`) gave, under `ParentAndLink`, `process orders` spans in the
  producer's traces with `parent_span_id` and link both naming the send span, and under
  `LinkOnly` roots of new traces linked to the same send spans.
- [x] M3 (2026-11-13): READMEs (trace-correlation section), envelope-conversion capability
  (bundle validates), changelog, demos (`OTEL_DEMO_LINK_ONLY`, `KAFKA_BROKER`) and version
  0.13.0.0 done. Publication is left to the user under the repository's release skill.


## Surprises & Discoveries

- FRIC-6 (2026-11-13): the private broker `shibuya-kafka-adapter-rp-0` (127.0.0.1:29092),
  generated by the nix-haskell-flake seihou module from mori://shinzui/redpanda-container's
  `defaults.nix`, is started with nixpkgs' `container` 1.1.0 CLI while the machine runs a 1.5.0
  apiserver; `redpanda-local-up` hung, and a 1.5.0-client `container start` of the same container
  also hung. The machine-wide shared broker on :9092 belongs to other projects and was not used.
  The user asked the redpanda-container session to fix the module and publish an updated
  nix-haskell-flake; after that, run `seihou update nix-haskell-flake` here.
- Test literals the plan's search missed: eight full `KafkaAdapterConfig` literals across tests
  and `LifecycleLive`, and one `Adapter` literal in `AckHandleTest`. `otel-demo` needed its
  `Shibuya.Adapter` import narrowed to `Adapter (source)` to avoid an ambiguous `telemetry`
  record update. The OTel demos hard-coded `localhost:9092`, the shared broker, so they now read
  `KAFKA_BROKER`.


## Decision Log

- Decision: Kafka defaults to `ParentAndLink`.
  Rationale: Kafka is normally consumed close to real time, users expect producer and consumer
  in one trace, and trace backends display parent/child more prominently than links. Replay,
  heavy lag, and wide fan-out are the cases for opting into `LinkOnly`. The conventions permit creation-context parenting for single messages and discourage that
  default when processing within another span. Document the choice and the framework's
  deliberate omission of ambient-context links; do not claim the default alone is a deviation.
  Date: 2026-11-11

- Decision: The setting is one `telemetry` field on `KafkaAdapterConfig`, not per topic.
  Rationale: The policy is a per-adapter constant in `shibuya-core` and is read once per
  processor. Per-topic policy would need a per-message decision on the hot path.
  Date: 2026-11-11


## Outcomes & Retrospective

The Kafka adapter adopts `shibuya-core` 0.13 with one strict `telemetry` field, default
`ParentAndLink`, and no change to conversion. Both shapes were proven in-process over the
scripted log and end to end against a real broker in the trace backend. The adapter's own
benchmark is unchanged.

Friction: FRIC-6 resolved. The private Redpanda would not start because the generated
`nix/redpanda.nix` drove the 1.5.0 apiserver with nixpkgs' `container` 1.1.0 CLI, and the Apple
Container network service had separately wedged. The redpanda-container session fixed the module
(redpanda-container 2107c28, nix-haskell-flake 0.40.0, applied here as `05accc5`) and, with the
user's approval, recovered the runtime by booting out every container job; a plain
`container system stop/start` had not restarted anything.

Remaining outside this plan: publishing 0.13.0.0, which needs the user's approval.


## Context and Orientation

This is a child of the Shibuya MasterPlan
`mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`
(file `docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md` in the Shibuya
repository). Prerequisite: `shibuya-core` 0.13.0.0 is published on Hackage. Confirm with
`cabal update && cabal info shibuya-core | head` and check Hackage itself, not only the local
package index. Publication is a hard prerequisite to starting this plan. If the release is unavailable,
leave this plan Not Started; do not substitute a source pin.

Find the adapter repository's location on disk with:

```bash
mori registry show shinzui/shibuya-kafka-adapter --full
```

All paths below are relative to that repository's root. It contains three packages:
`shibuya-kafka-adapter` (the library and its test suite `shibuya-kafka-adapter-test`),
`shibuya-kafka-adapter-jitsurei` (runnable examples, including `otel-demo`, `otel-producer-demo`
and `otel-upstream-probe` under `app/`), and `shibuya-kafka-adapter-bench` (benchmark
`shibuya-kafka-adapter-bench` and executable `lifecycle-live`). Read that repository's
`CLAUDE.md` and `Justfile` first; the Justfile has recipes for the local Redpanda broker
(`redpanda-up`, `create-topics`) and Jaeger (`jaeger-ui`).

What `shibuya-core` 0.13 changed, which is all this plan needs to know about it. The adapter
interface gained a strict field:

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

The framework, not the adapter, creates the processing span. It reads the adapter's
`telemetry.traceCorrelation` once, and for each message that carries `Envelope.traceContext` (the W3C
`traceparent`/`tracestate` header pairs) it always adds a link to that context, and makes the
context the span's parent only under `ParentAndLink`. Under `LinkOnly` a usable creation context yields a root in a
new trace. Without usable headers, both policies preserve ambient parentage and emit no link. Batch spans (when the user wraps the adapter in a batching processor) always link
the first 128 members with valid contexts, count the exact valid remainder, and never
take a parent, regardless of this setting. If the constructor names
differ in the published 0.13, follow the published API and note it in Surprises & Discoveries.

The same `shibuya-core` release renames the processing span from `<destination> process` to
`process <destination>` and adds the attribute `messaging.operation.name = "process"`. Search
this repository for the old form (`grep -rn ' process"\|process`' --include='*.hs' --include='*.md' .`)
and update every test, example and document that matches it; note the rename in the changelog.

Where the adapter stands today. `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Config.hs`
defines `KafkaAdapterConfig` with fields `topics`, `pollTimeout`, `batchSize` and
`defaultConfig :: [TopicName] -> KafkaAdapterConfig`.
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka.hs` constructs the single `Adapter` record
(around the line `adapterName = "kafka:" <> …`).
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs` fills `Envelope.traceContext` from
the record's `traceparent`/`tracestate` headers; this plan does not touch it. The four cabal
files pin `shibuya-core ^>=0.12.0.0`. The library version is 0.12.0.0.

Decision records in that repository are plain Markdown files under `docs/adr/` (numbered,
no frontmatter); the existing three concern acknowledgement fencing and retry barriers and are
not affected. Capability documents under `docs/capabilities/` are a profile-governed bundle
(see `mori.dhall` there); `docs/capabilities/envelope-conversion.md` describes trace-context
extraction. The Shibuya-side decision that this plan follows is recorded in the Shibuya
repository's correlation ADR (ADR 0014, implemented by Shibuya plan 55; cite it by the canonical URI that
`mori registry concepts --search 'trace correlation' --json` returns, or, if the registry does
not list it, as `mori://shinzui/shibuya` plus its path under `docs/adr/`, stating that the
artifact-level URI is pending).

Performance and space. The adapter's only code change is one strict enumeration field set at
construction; nothing is added to the per-record path, and `Convert.hs` is unchanged. The cost
of the link itself is in `shibuya-core` and was gated there. The obligation here is to confirm
that the adapter's own benchmark is unchanged after the dependency bump and that no laziness is
introduced: the config field and the `Adapter` field must both be strict.


## Plan of Work

### Milestone 1: compile against 0.13 and expose the setting

Raise the `shibuya-core` bound to `^>=0.13.0.0` in all four cabal stanzas that name it
(library and test in `shibuya-kafka-adapter.cabal`, `shibuya-kafka-adapter-jitsurei.cabal`,
both stanzas in `shibuya-kafka-adapter-bench.cabal`). Verify the published version on Hackage
before choosing the bound.

Add `telemetry :: !AdapterTelemetry` to `KafkaAdapterConfig` with a Haddock comment stating the
default policy and when to choose `LinkOnly`; set it to `defaultAdapterTelemetry` in
`defaultConfig` (its policy is already `ParentAndLink`). Re-export `TraceCorrelation (..)`,
`AdapterTelemetry`, its field and `defaultAdapterTelemetry` from `Shibuya.Adapter.Kafka` so
users need no extra import. Set `telemetry = config.telemetry` in the `Adapter` construction in
`Kafka.hs`.
Fix any other `Adapter { … }` or `KafkaAdapterConfig { … }` literal the compiler reports in
tests, examples, or benchmarks.

Extend the unit tests (`shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/AdapterTest.hs` or the
nearest fit) to assert that `defaultConfig` yields `ParentAndLink` and that an adapter built
from a config with `LinkOnly` exposes `LinkOnly` on its `Adapter` record.

### Milestone 2: prove the span shape and the absence of regression

Add a test that runs the adapter's processing path with tracing enabled and an in-memory span
exporter (the `hs-opentelemetry-exporter-in-memory` package, as used in `shibuya-core`'s own
telemetry tests) and asserts, for a record carrying a known `traceparent`: under the default,
the processing span has the producer's trace ID, the producer's span as parent, and one link to
it; under `LinkOnly`, a different trace ID, no parent, and the same link. Prefer the broker-free
route if the test suite has a way to feed records without Kafka (see `SourceGateTest.hs` and
`ConvertTest.hs` for existing broker-free patterns); otherwise add it to `IntegrationTest.hs`
and run it against the local Redpanda.

Run the adapter benchmark before and after. Capture a baseline from a worktree of the previous
release tag, then compare the working tree, as shown in Concrete Steps. The expected result is
no change beyond noise in time and no change in allocation for cells that run with tracing
disabled. If the benchmark runs any cell with tracing enabled and headers present, an allocation
increase equal to one link per message is expected there and must be recorded with its size; any
other increase must be explained before continuing.

Before completing documentation or this plan, require M2 of
`mori://shinzui/shibuya/plans/58-adopt-trace-correlation-in-the-pgmq-adapter` accepted,
including its link-only dead-letter test. The MasterPlan schedules that check first.

### Milestone 3: documentation and version

Update `README.md` and `shibuya-kafka-adapter/README.md` with a short "Trace correlation"
section: the default, the qualified OTel recommendation for processing within another span,
the no-header ambient-parent exception, how to set `LinkOnly`,
the three Kafka situations that call for it
(replay from an old offset, sustained lag, many consumer groups on one topic), the effect on
sampling (a link-only trace is sampled independently of the producer's), and the fixed batch
behaviour (a root span with one link per record carrying `messaging.message.id`). Update `docs/capabilities/envelope-conversion.md` where it says end-to-end span shape
is determined by the framework, pointing at the new setting; keep that bundle's frontmatter
valid and run its validation as that repository's instructions describe. Update the `otel-demo`
example to read the policy from an environment variable or flag so both shapes can be shown.

Add a changelog entry in `shibuya-kafka-adapter/CHANGELOG.md`. Adding a field to an exported
record with exported constructor is a breaking change under the PVP, so the version becomes the
next major (0.13.0.0); follow that repository's release skill
(`agents/skills/release/SKILL.md`) for the bump and release.

No new ADR is needed in the adapter repository unless implementation produces a durable
adapter-specific decision; the default and its rationale are recorded in the Shibuya MasterPlan
and ADR. If one is written, follow the plain convention of `docs/adr/` there.

In the Shibuya repository, mark this plan Complete in the MasterPlan registry and update its
Progress.


## Concrete Steps

In the adapter repository root, inside its nix devShell:

```bash
cabal update
cabal build all
cabal test shibuya-kafka-adapter
nix fmt
```

For tests that need a broker:

```bash
just process-up
just create-topics
cabal test shibuya-kafka-adapter
```

Benchmark comparison, where `<last-tag>` is the previous release tag (`git tag --sort=-v:refname | head`):

```bash
git worktree add /tmp/kafka-adapter-baseline <last-tag>
( cd /tmp/kafka-adapter-baseline && \
  cabal bench shibuya-kafka-adapter-bench \
    --benchmark-options="--stdev 5 --timeout 120 --csv /tmp/kafka-adapter-baseline.csv" )
cabal bench shibuya-kafka-adapter-bench \
  --benchmark-options="--stdev 5 --timeout 120 --baseline /tmp/kafka-adapter-baseline.csv --fail-if-slower 10"
git worktree remove /tmp/kafka-adapter-baseline
```

If that benchmark does not accept `tasty-bench` options, read
`shibuya-kafka-adapter-bench/bench/Main.hs` and use its equivalent, recording the command used.

Seeing it in Jaeger:

```bash
just process-up
just jaeger-ui
cabal run otel-producer-demo
cabal run otel-demo            # default: ParentAndLink
# then again with the LinkOnly setting added in Milestone 3
```

Expected: with the default, the producer's trace contains the `process <destination>` span as a child;
with `LinkOnly`, the process span appears as its own trace whose span detail lists one link
(Jaeger shows it under "References") to the producer's span.

Commit messages in the adapter repository follow Conventional Commits and carry:

```text
MasterPlan: mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans
ExecPlan: mori://shinzui/shibuya/plans/57-adopt-trace-correlation-in-the-kafka-adapter
Intention: intention_01m76tvgq9epqr5p2vdekeetxe
```


## Validation and Acceptance

The adapter builds and its whole test suite passes against `shibuya-core` 0.13 resolved from
Hackage, with no `source-repository-package` override for Shibuya left in `cabal.project`.

`(defaultConfig ts).telemetry.traceCorrelation == ParentAndLink`. The span-shape test passes for both
settings as described in Milestone 2.

The benchmark comparison exits 0 with no unexplained allocation increase.

A reader of the README can find the setting, its default, and when to change it.


## Idempotence and Recovery

All steps are ordinary edits and can be repeated. The bound change is reversible. If Hackage
does not yet have the target release, leave the plan Not Started; do not weaken bounds or
substitute a source pin. Remove worktrees after use. Stopping the local
services is `just process-down`.


## Interfaces and Dependencies

Prerequisite from the parent MasterPlan: Shibuya plan 55 (the policy in `shibuya-core`) Complete
and the release gate passed (`shibuya-core` 0.13.0.0 on Hackage). Shibuya plan 56 (batch links)
is a soft dependency: it only affects what the documentation says about batches.

Consumes from `shibuya-core` `^>=0.13.0.0`: `Shibuya.Adapter.Adapter` with the
`telemetry` field, `Shibuya.Adapter.AdapterTelemetry` with `defaultAdapterTelemetry`, and
`Shibuya.Adapter.TraceCorrelation (..)`.

Provides:

```haskell
-- Shibuya.Adapter.Kafka.Config
data KafkaAdapterConfig = KafkaAdapterConfig
  { topics :: ![TopicName],
    pollTimeout :: !Timeout,
    batchSize :: !BatchSize,
    telemetry :: !AdapterTelemetry  -- default: traceCorrelation = ParentAndLink
  }
```

No other plan depends on this one.

Revision note (2026-11-12): publication now blocks implementation, the PGMQ integration
sequence is explicit, and correlation/conformance documentation includes the no-header
exception and qualified OTel recommendation. Existing benchmark scope is unchanged.
