---
id: 8
slug: configurable-trace-correlation-for-consumer-spans
title: "Configurable trace correlation for consumer spans"
kind: master-plan
created_at: 2026-11-12T02:55:43Z
intention: "intention_01m76tvgq9epqr5p2vdekeetxe"
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
      at: 2026-11-12T04:52:36Z
      mode: "update"
      note: "Export the processing-span function for Keiro"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:42:29Z
      mode: "update"
      note: "Apply review corrections and record unresolved contracts without changing benchmark scope."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:51:06Z
      mode: "update"
      note: "Resolve review contracts and sequencing; retain benchmark scope and external verification limits."
    - model: "claude-opus-5-5"
      harness: "claude-code"
      at: 2026-11-12T23:12:57Z
      mode: "implement"
      note: "Coordinate EP-1 onward; registry and progress updates"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:42:29Z
      verdict: "changes-requested"
      note: "Resolve ambient context, release prerequisites, helper ownership and batch accounting; external verification limited by Mori outage."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:51:06Z
      verdict: "comments"
      note: "Follow-up: planning findings resolved; document checks pass; dependency, adapter and runtime validation remain implementation prerequisites."
---

# Configurable trace correlation for consumer spans

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

Shibuya opens one OpenTelemetry span of kind Consumer around the processing of each message
(or each batch). Today that span is always made a child of the span that produced the message:
`processOne` in `shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` decodes the W3C
`traceparent` header carried in `Envelope.traceContext`, attaches it as the parent, and creates
the span with an empty link list. A batch span uses the first member's context as its parent
and discards the others.

A span "link" is a second kind of relationship in OpenTelemetry: a span records the identity of
another causally related span without joining its trace. The OpenTelemetry messaging semantic
conventions say a "Process" span SHOULD link to the creation context of every message it
accounts for, that creation-context parenting is discouraged by default when processing inside another
span and is allowed only for single messages, and that instrumentations MAY make this configurable and
SHOULD document what they do. Shibuya currently does the opposite of the default.

Parenthood across a queue is wrong for some sources. An event-store subscription replays events
written months earlier, and several subscribers read the same event; a job that is retried or
delayed stretches the producer's trace indefinitely; a tail-sampling collector decides per trace
inside a time window and drops consumer spans that arrive late; a batch has many producers but a
span has one parent.

After this initiative:

- Consumer spans link usable creation contexts at creation so samplers can see them; batches
  retain the first 128 valid member links and report the exact valid remainder count.
- Each adapter declares a trace correlation policy, `ParentAndLink` or `LinkOnly`, exposed in
  that adapter's configuration. `ParentAndLink` keeps today's single connected trace and adds
  the link. `LinkOnly` starts a new root trace when a valid creation context exists and relates it to
  the producer only by link. Without usable headers both policies preserve ambient parentage.
- Batch spans never use a member's context as parent. They link every member, bounded.
- Kafka and PGMQ default to `ParentAndLink`; Kiroku defaults to `LinkOnly`.
- Processing spans are named `process <destination>` and carry the Required attribute
  `messaging.operation.name`, as the conventions specify, replacing `<destination> process`.
- None of this costs anything when tracing is disabled, has measured enabled-path costs with bounded link storage
  and a full batch scan for exact overflow accounting, and retains no message data beyond what a span retains today.

Performance and space safety are first-class scope, not a closing check. The initiative begins
by adding the tracing-enabled benchmarks and heap-retention tests that do not exist today (every
benchmark in `shibuya-core-bench` runs under `runTracingNoop`), so each later change is measured
against a baseline taken on unchanged behaviour.

Excluded: creating "Receive" or "Settle" spans; changing span kinds or lifecycle span names;
changing existing `messaging.*` attributes (the additions are `messaging.batch.message_count` on
batch spans, in EP-3, and `messaging.operation.name`, in EP-7); extracting context through the configured propagator instead of reading W3C headers
directly; propagating baggage; a links-aware sampler; changing how adapters extract
`traceContext`; the archived `shinzui/shibuya-message-db-adapter`; and any change to the
producer side (`currentTraceHeaders`, `injectTraceContext`).

### Conformance to the OpenTelemetry messaging conventions

The whole of the messaging spans document
(`docs/messaging/messaging-spans.md` in `open-telemetry/semantic-conventions`, status
Development) was read on 2026-11-11. What it requires, and where this initiative stands:

- "For each message it accounts for, the "Process" or "Receive" span SHOULD link to the
  message's creation context." Met for single messages (EP-2) and batches (EP-3).
- Single-message processing may use the creation context as parent. The recommendation
  against doing so by default is qualified to processing inside another span; Kafka and PGMQ's
  defaults alone are not a deviation. Instrumentation must document its chosen behavior.
- With a meaningful ambient operation, the conventions recommend preserving that relationship
  through parentage or a link. Shibuya deliberately does not preserve it when valid creation
  headers are supplied, including through its public helpers. This is a documented limitation.
  Without usable headers, single-message processing retains ambient parentage under both
  policies; batches always clear it. See ADR 0014 for the complete contract.
- For batches, attributes whose values vary per message "SHOULD" be set "on links describing
  individual messages", and the document's batch example sets `messaging.message.id` on each
  link and `messaging.batch.message_count` on the span. Met by EP-3.
- "Process" spans have kind `CONSUMER`. Already met.
- The span name "SHOULD be `{messaging.operation.name} {destination}`" and
  `messaging.operation.name` is Required. Shibuya emits `<destination> process` and sets only
  `messaging.operation.type` today. Met by EP-7. One residue: the destination in the name is
  the processor identifier, which differs from `messaging.destination.name` when an adapter
  overrides that attribute per message.
- Not met and out of scope, recorded so it is not rediscovered: "Settle" spans "SHOULD be
  created for every ... settlement operation" while Shibuya records the acknowledgement as an
  event on the processing span. This predates the initiative and adds a span per message, a
  cost that needs its own evaluation.
- The document does not say how the creation context is carried or which propagator to use, and
  does not mention baggage, so reading W3C headers directly breaks no rule in it.


## Decomposition Strategy

The work splits by behaviour and by repository. Seven child plans:

Measurement comes first and is its own plan (EP-1) because its output, benchmark groups and
retention tests that exercise the tracing-enabled path, must exist in a committed tree *before*
any behaviour changes; the later plans build that tree in a git worktree to capture their
baseline. Folding it into the first feature plan would leave no clean "before" commit.

The core policy for single messages (EP-2) owns every shared interface: the `TraceCorrelation`
type, the `Adapter` record field, and the helper that turns trace headers into a link. It is the
only plan that changes a public record in `shibuya-core`.

Batch fan-in links (EP-3) is separate from EP-2 because it is a different behaviour with a
different risk: the link list grows with batch size and must be bounded, and it removes a
parent rather than making one optional. It is not configurable, so it does not depend on the
policy type, only on the link helper.

Span naming (EP-7) is separate because it is unrelated to parent-versus-link, breaks a
different thing for users (queries that match the span name), and has its own small cost to
measure. It was added on 2026-11-11 so that the one breaking release carries every change to
what tracing emits.

Each adapter (EP-4 Kafka, EP-5 PGMQ, EP-6 Kiroku) is one plan because each lives in its own
repository with its own release, tests, and documentation, and each has a distinct question to
answer: Kafka's replay and consumer-group fan-out, PGMQ's dead-letter header merge, Kiroku's
change of default. They do not touch each other.

Alternatives rejected. A single ExecPlan would span four repositories and two releases and hide
the baseline-before-change ordering. Putting the policy on `QueueProcessor` or `AppConfig`
instead of `Adapter` was rejected because the right default is a property of the source (an
event store replays; a job queue does not), and the adapter's own configuration is already
user-supplied, so it serves as the override. A per-message policy on `Envelope` was rejected
for hot-path cost. A third `ParentOnly` policy (today's behaviour, no link) is not offered up
front; EP-2 measures the link's cost and reopens this only if the cost is material.

Relevant local ADRs, read for this plan:

- [ADR 0012](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md):
  adapters supply incoming context and attributes; the framework owns the Consumer span;
  disabled tracing shares one no-op provider and a sentinel span; exactly one Consumer span per
  individually processed message. This initiative keeps that ownership split: adapters declare a
  policy, the framework applies it.
- [ADR 0006](../adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md):
  an allocation increase is a regression even when time is within noise, and
  `hs-opentelemetry-*` is a hot-path dependency. The performance gates below adopt the same
  rule.
- [ADR 0013](../adr/0013-let-adapters-supersede-a-delivery-before-its-handler-runs.md): a
  superseded delivery still opens its processing span and ends it successfully; the batch worker
  filters superseded members before the batch span. EP-2 and EP-3 must preserve this.
- [ADR 0001](../adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md): garbage
  collection behaviour is tested in process-isolated suites. EP-1 follows that pattern.

No cross-repository ADR on trace correlation was found (`mori registry concepts --search` for
"trace context" and "span link" returned capability records only).

Proposed [ADR 0014](../adr/0014-define-consumer-correlation-and-bounded-batch-link-accounting.md) records the correlation
contract and batch accounting. EP-2 adds implementation evidence; EP-3 and EP-7 extend it
with their measured results. Proposed status does not claim implemented behavior.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Establish tracing-enabled performance and retention baselines | docs/plans/54-establish-tracing-enabled-performance-and-retention-baselines.md | None | None | Complete |
| 2 | Add an adapter-declared trace correlation policy to single-message processing | docs/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md | EP-1 | None | Complete |
| 3 | Link every batch member's creation context from the batch span | docs/plans/56-link-every-batch-member-s-creation-context-from-the-batch-span.md | EP-1, EP-2 | None | In Progress |
| 4 | Adopt trace correlation in the Kafka adapter | docs/plans/57-adopt-trace-correlation-in-the-kafka-adapter.md | EP-2, Release gate | EP-3, EP-7 | Not Started |
| 5 | Adopt trace correlation in the PGMQ adapter | docs/plans/58-adopt-trace-correlation-in-the-pgmq-adapter.md | EP-2, Release gate | EP-3, EP-7 | Not Started |
| 6 | Adopt trace correlation in the Kiroku adapter with a link-only default | docs/plans/59-adopt-trace-correlation-in-the-kiroku-adapter-with-a-link-only-default.md | EP-2, Release gate | EP-3, EP-7 | Not Started |
| 7 | Name process spans and operations per the messaging conventions | docs/plans/60-name-process-spans-and-operations-per-the-messaging-conventions.md | EP-1 | EP-2, EP-3 | In Progress |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
A whole-child hard dependency requires that child to be Complete. If only a milestone's
accepted output is needed, name it explicitly (e.g., EP-1 M1) and explain it below.


## Dependency Graph

EP-1 blocks EP-2 and EP-3 as a whole. Both need the benchmark group `tracing` and the retention
test suite to exist in a commit that predates their changes, because their performance gate
compares the working tree against a worktree of that commit.

EP-3 requires EP-2 Complete, including its link helpers, `withRootContext` from M2,
accepted single-message behavior and ADR evidence. EP-2 owns those helpers; EP-3 consumes
them. Run EP-2 to completion, then EP-3, using EP-2's final commit as the baseline.

EP-7 needs only EP-1 for its benchmark baseline and uses nothing EP-2 or EP-3 define, but it
edits the same runner code, tests and documents. Run it third among the core plans, after EP-3,
with its baseline taken at EP-3's final commit, so that each gate still measures one change.

The release gate sits between the core plans and the adapter plans. The three adapters depend on
`shibuya-core` from Hackage with the bound `^>=0.12.0.0` (Kiroku: `>=0.12 && <0.13`). Adding a
field to the `Adapter` record is a breaking change, so the adapters cannot compile against the
new core until `shibuya-core` 0.13.0.0 is published. Publish once, after EP-2, EP-3 and EP-7 are
all Complete, so the record change, the batch behaviour change and the span rename ship in a
single breaking release.
Use the repository's release skill (`agents/skills/release/SKILL.md`), which runs the benchmark
regression gate against the previous tag. Publication is a hard prerequisite to starting
adapter implementation. Do not bypass it with a source pin. Verify Hackage and upstream tags
at release time before choosing final versions and bounds; version numbers here are targets.

EP-3 and EP-7 are soft dependencies of the adapter plans in the sense that no adapter library
code depends on them, but both are in the release the adapters build against: each adapter's
documentation describes the batch behaviour, and each adapter plan must update any test, example
or document that matches the old span name `<destination> process`.

After the release gate, execute EP-5 through M2, accepting its link-only dead-letter check,
then finish EP-5, EP-4 and EP-6 in that order. EP-4 and EP-6 implementation has no code-level
dependency on EP-5, but their documentation/completion must follow its accepted M2 check.
This explicit milestone sequence takes precedence over registry row order.


## Integration Points

**The `TraceCorrelation` type, the `AdapterTelemetry` record and the `Adapter.telemetry`
field.** Defined by EP-2,
consumed by EP-4, EP-5, EP-6.

```haskell
-- module Shibuya.Telemetry.Correlation, re-exported from Shibuya.Adapter, Shibuya.Telemetry and Shibuya
data TraceCorrelation
  = ParentAndLink
  | LinkOnly
  deriving stock (Eq, Show, Generic, Enum, Bounded)
  deriving anyclass (NFData)

-- | Telemetry options an adapter declares. Build it from
-- 'defaultAdapterTelemetry' with record update; the constructor is not
-- exported, so options can be added later without breaking adapters.
data AdapterTelemetry = AdapterTelemetry
  { traceCorrelation :: !TraceCorrelation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | @traceCorrelation = ParentAndLink@.
defaultAdapterTelemetry :: AdapterTelemetry

-- module Shibuya.Adapter
data Adapter es msg = Adapter
  { adapterName :: !Text,
    source :: Stream (Eff es) (Ingested es msg),
    shutdown :: Eff es (),
    telemetry :: !AdapterTelemetry
  }
```

`AdapterTelemetry` is exported with its field but without its constructor. A value is obtained
only from `defaultAdapterTelemetry` and changed with record update
(`defaultAdapterTelemetry {traceCorrelation = LinkOnly}`), so a later option becomes a new field
with a default and no adapter has to change. This is the reason the policy is not a bare field
on `Adapter`: `Adapter` is constructed by record literal in three adapter repositories, and
every field added to it is a coordinated breaking release.

Each adapter plan adds a `telemetry :: !AdapterTelemetry` field to its own configuration record,
defaults it to `defaultAdapterTelemetry` with the `traceCorrelation` given in the Vision above,
and copies it into `Adapter` unchanged. Adapters do not interpret the value, and carrying the
whole record means future options reach users without an adapter code change. If EP-2 changes
the constructor set of `TraceCorrelation` (for example by adding `ParentOnly`), it updates this
section first and the adapter plans follow.

**The link helper and root-context operation.** EP-2 owns `withRootContext` in
`Shibuya.Telemetry.Effect` (M2), consumed by EP-3. Link helpers are defined by EP-2 M1 in `Shibuya.Telemetry.Correlation`, consumed by EP-3.
`creationLink :: TraceHeaders -> Maybe NewLink` decodes trace headers into a link whose
`SpanContext` is fully evaluated and whose attribute map is the shared empty map, and
`creationLinkWith :: AttributeMap -> TraceHeaders -> Maybe NewLink` does the same with
caller-supplied link attributes. EP-3 must use these rather than decoding headers a second way;
it passes each member's `messaging.message.id` as the link attribute.

**The shared processing-span function.** Defined by EP-2 in the new public module
`Shibuya.Telemetry.Process`: `withProcessSpan` (in the `Tracing` effect) and `withProcessSpanIO`
(for a plain `Tracer`). Shibuya's own `processOne` is built on it. Its consumers are outside
this MasterPlan: Keiro's `keiro-pgmq` bounded drain, which copies the span by hand today, and
Keiro's subscription workers, which have none, both planned under
`mori://shinzui/keiro/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries`.
That MasterPlan is blocked on this one's release gate. EP-3 does not use the function, since
batch spans have their own link collection.

**`processSpanName`, `consumerSpanArgs` and the Consumer span.** `consumerSpanArgs` in
`shibuya-core/src/Shibuya/Telemetry/Semantic.hs` is a shared constant with `links = []`. It
stays exported and unchanged; EP-2 adds a function that builds arguments carrying links. Both
EP-2 and EP-3 call it.

**The performance and retention contract.** Defined by EP-1 as executable checks; EP-2 and EP-3
must pass them and extend them to the new paths; the adapter plans restate the parts that apply.
Every plan in this initiative is bound by these rules:

1. Disabled tracing (`runTracingNoop`) allocates nothing new per message and decodes no header.
   The policy is read once per processor, never per message.
2. In EP-2, enabled single-message processing without usable headers retains its behavior and
   cost. EP-3 may add root-context attachment and batch-count attributes; EP-7 may add the
   operation-name map entry. These existing allowances must be measured and explained, not
   treated as blanket performance waivers.
3. For single messages with tracing enabled and usable `traceContext`, the added cost is one link: a bounded constant per
   message, measured and recorded in the plan. A time regression beyond the benchmark gate, or
   an allocation increase that the one link does not explain, stops the plan for a decision.
4. Nothing reachable from a span, live or ended, may reference the `Ingested`, the `Envelope`,
   the payload, or a lazy thunk over them. A link holds only an evaluated `SpanContext` and, on
   batch spans, the member's evaluated message identifier. Link lists and link attributes are
   fully evaluated before the span is created.
5. A batch span stores at most 128 links. Exact overflow accounting requires a full scan
   and decoding of remaining headers; total work and transient decode allocation may scale
   with batch size and header length. Only retained link storage is bounded by the link cap.
6. Heap residency under sustained processing is flat: live bytes after ten times as many
   messages are not materially larger.

The benchmark gate is the one the release skill already uses: `tasty-bench` with a CSV baseline,
`--fail-if-slower 10 --stdev 5`, and inspection of the `allocated` column, where any unexplained
increase is a regression.

**`docs/user/opentelemetry.md`, `docs/capabilities/opentelemetry-tracing.md`,
`shibuya-core/CHANGELOG.md` and the correlation ADR.** EP-2, EP-3 and EP-7 all edit them. EP-2
writes the correlation section and adds implementation evidence to ADR 0014; EP-3 adds the batch paragraph; EP-7 rewrites
the span-name subsection and moves naming from the ADR's known gaps to its conformance
statement. Run sequentially as described above to avoid conflicts.

**`processSpanName` and the span name seen by adapters.** Changed by EP-7 from
`<destination> process` to `process <destination>`. The adapter plans consume the new name in
tests and documentation. Known occurrence: the PGMQ adapter's `ChaosSpec.hs` selects spans named
`"dlq-identity process"`.

**Cross-repository citation.** The adapter plans live in this repository but are implemented in
others. Commits made in an adapter repository cite the plan and this MasterPlan by canonical URI,
for example `mori://shinzui/shibuya/plans/57-adopt-trace-correlation-in-the-kafka-adapter` and
`mori://shinzui/shibuya/masterplans/8-configurable-trace-correlation-for-consumer-spans`, in the
`ExecPlan:` and `MasterPlan:` trailers. Verify URI resolution when registry access is available; retain canonical URIs even
when resolution is unavailable.

**Representative producer/consumer check.** The uncertain shared behaviour is whether a
`LinkOnly` span is truly a new root and still carries a usable link when driven by a real
adapter. EP-2 proves it in-process with the in-memory exporter. EP-5 (PGMQ) is the first
adapter-level check because its test suite already runs against a real PostgreSQL and asserts on
trace headers in the dead-letter path; run EP-5's link-only dead-letter test before finalising
EP-4 and EP-6 documentation.


## Progress

EP-1 and EP-2 are Complete (2026-11-12). EP-1 recorded the `tracing` baseline and the
retention suite. EP-2 links single-message spans and adds the adapter policy and
`Shibuya.Telemetry.Process`, and lowers per-message allocation. EP-3 is next, with its baseline
at EP-2's final commit. On
2026-11-12 the user authorized the benchmark scope exactly as the child plans specify it
(EP-1's group and baseline; EP-2, EP-3 and EP-7's added cells and worktree comparisons), and
nothing beyond it.

Cross-plan gates not owned by a child plan:

- [ ] Release gate: `shibuya-core` 0.13.0.0 published to Hackage after EP-2, EP-3 and EP-7 are
  Complete, with the release skill's benchmark regression gate passing against 0.12.0.0 and no
  unexplained increase in the `allocated` column for the existing `hot-path`, `handler`,
  `concurrency` and `framework` groups.
- [ ] Initiative acceptance: with all three adapters released, one end-to-end trace per adapter
  viewed in a trace backend (the local Jaeger setup in `docs/JAEGER_LOCAL_TESTING.md`) shows
  spans named `process <destination>` and the documented default shape: Kafka and PGMQ processing spans as children of the producer with a
  link, Kiroku processing spans as separate roots with a link.


## Surprises & Discoveries

### Review resolution — 2026-11-12

The initial review requested changes; this update resolves its planning findings. All seven
child paths exist and the dependency graph is acyclic. The MasterPlan and all children were
authored by `claude-fable-5-2`, with no recorded reviews before this session.

The no-header exception is now explicit; the shared public helper documents its ambient-context
limitation. EP-3 requires EP-2 Complete, leaving root-context ownership solely with EP-2.
Publication blocks adapter implementation, and the explicit sequence accepts EP-5 M2 before
EP-4/EP-6 documentation. Batch overflow counts remain exact through a full decode scan, with
bounded retained links rather than a constant-work promise. Performance allowances match the
existing child criteria. Retention counts distinguish Consumer and lifecycle spans. All release
instructions include EP-7. [ADR 0014](../adr/0014-define-consumer-correlation-and-bounded-batch-link-accounting.md) records the proposed durable contract.

The [messaging conventions](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/)
qualify their recommendation against creation-context parenting to processing within another
span. Conformance prose now preserves that qualification and explicitly documents the helper's
ambient-context limitation. Adapter defaults remain unchanged.

Local sources and relevant ADRs were inspected. Mori registry access failed because its
PostgreSQL socket refused connections; adapter checkouts, dependency internals and published
versions/tags remain unverified. No builds, benchmarks or services were run for this review.

- EP-1 (2026-11-12): hs-opentelemetry creates non-recording spans when a provider has no span
  processors (`tracerProviderHasProcessor`). Any enabled-path measurement or retention check in
  EP-2, EP-3 or EP-7 must use a provider with at least one processor; `Bench.Tracing` and the
  retention suite use one that discards every span. EP-1 also confirmed the disabled-path
  decode cost below: about 346–360 bytes per message.
- EP-2 (2026-11-12): time gates on this shared 36-core machine are unreadable under concurrent
  load. Concurrent cells slowed 15–48% in unchanged code while allocation stayed exact (FRIC-2,
  resolved by a note in `shibuya-core-bench/README.md`). EP-3 and EP-7 should run their gates on
  an idle machine and read allocation first. EP-2 also found ten positional `Adapter`
  constructions in this repository that the plans' record-syntax grep missed. The adapter plans
  (EP-4 to EP-6) should expect positional sites in their repositories too.
- EP-2 (2026-11-12): the link is cheaper than nothing. Single-message processing allocates about
  208 bytes per message less, and the headers-plus-link path costs less than before, so the
  `ParentOnly` question in the Decision Log is closed.
- The disabled path may already decode headers. `processOne` binds
  `parentCtx = ingested.envelope.traceContext >>= extractTraceContext` and passes it to
  `withExtractedContext`, which pattern-matches on the `Maybe` before it checks whether tracing
  is enabled. For a message that carries a `traceparent`, that match forces the W3C decode even
  under `runTracingNoop`. No existing benchmark sets `traceContext`, so this has not been
  measured. EP-1 adds the benchmark that exposes it; EP-2 fixes it by checking the enabled flag
  first. Found by reading the source on 2026-11-11; not yet confirmed by measurement.
- No benchmark exercises tracing-enabled processing. Every module under
  `shibuya-core-bench/bench/` uses `runTracingNoop`. This is why EP-1 exists.
- The ambient context is not always empty. `withExtractedContext Nothing` leaves the thread's
  current OpenTelemetry context in place, and the unsupervised runner path runs processing on
  the caller's thread. A `LinkOnly` span must therefore clear the context explicitly to be a
  root; it cannot rely on there being no ambient span.
- The SDK caps links per span (`tracerLinkCountLimit`, default 128) and counts the rest as
  dropped. EP-3 bounds its own list at 128; a lower configured SDK limit can still drop
  supplied links independently of Shibuya's exact pre-SDK overflow count.


## Decision Log

- Decision: The policy is declared by the adapter (inside the strict `Adapter.telemetry` field) and exposed
  through each adapter's configuration, not set on `QueueProcessor` or `AppConfig`.
  Rationale: The correct default depends on the source's semantics, which the adapter knows;
  the adapter configuration is already supplied by the user, so no second override is needed.
  This keeps ADR 0012's split, where adapters supply context and the framework owns the span.
  Date: 2026-11-11

- Decision: The policy sits inside an `AdapterTelemetry` record with a default value and an
  unexported constructor, held in a single `Adapter.telemetry` field.
  Rationale: Likely later options (a per-message rule such as linking only old or redelivered
  messages, a switch for settle spans) would each otherwise add a field to `Adapter` and force a
  breaking release of the core and three adapters. One extensible record costs one extra type
  now; the runner still reads it once per processor. The record solves extensibility only; it
  does not itself provide those options.
  Date: 2026-11-11

- Decision: EP-2 exports the processing-span construction as a public function.
  Rationale: Keiro needs the same span in two places that do not run under Shibuya's runner, and
  already carries a hand-written copy that its own decision record flags as able to drift. A
  shared function is cheaper than a second and third copy and lets a later change to the rule
  reach every user.
  Date: 2026-11-11

- Decision: Two policies, `ParentAndLink` and `LinkOnly`; the link is always emitted.
  Rationale: The messaging conventions make the link the baseline and parenthood the option.
  Offering a no-link policy would preserve the non-conformant behaviour as a choice. EP-2
  measures the link's cost and may reopen this if it is material.
  Date: 2026-11-11

- Decision: Batch spans link all members and take no member as parent, with no configuration.
  Rationale: A span has one parent, so any parent choice misattributes the batch; the
  conventions say links are the only correct correlation for batches.
  Date: 2026-11-11

- Decision: Defaults are `ParentAndLink` for Kafka and PGMQ, `LinkOnly` for Kiroku.
  Rationale: Kafka and PGMQ are normally consumed soon after production and users expect one
  connected trace, which is also how trace backends display best. Kiroku subscriptions replay
  and catch up long after the writing trace ended and fan out to several subscribers.
  Date: 2026-11-11

- Decision: Keep Kafka/PGMQ defaults for compatibility and document the qualified OTel rule.
  Rationale: Creation-context parenting is allowed for single messages; its default is discouraged
  in the scope of another span, not universally. Supersedes the earlier blanket deviation claim.
  Date: 2026-11-12

- Decision: Preserve ambient parentage without usable headers; suppress it when valid headers
  select the producer parent or a linked root. Batches remain roots; no ambient links are added.
  Rationale: Preserve EP-2's existing no-header compatibility and explicitly limit the public
  helpers to independent processing. Direct callers can have meaningful ambient operations,
  so the limitation is documented rather than dismissed as inapplicable.
  Date: 2026-11-12

- Decision: Each batch link carries the member's `messaging.message.id`, one link per member
  with a creation context, and the batch span carries `messaging.batch.message_count`.
  Rationale: The conventions put per-message attributes that vary on the links, and their batch
  example does exactly this. It replaces an earlier draft that collapsed adjacent members
  sharing a context, which would have lost the second member's identifier.
  Date: 2026-11-11

- Decision: "Settle" spans and propagator-based extraction stay out of scope.
  Rationale: They are existing gaps unrelated to parent-versus-link. A settle span adds a span
  per message and needs its own cost evaluation. They are listed in the conformance section.
  Date: 2026-11-11

- Decision: Add EP-7 to rename processing spans to `process <destination>` and set
  `messaging.operation.name`, inside this initiative and its single release. This reverses an
  earlier decision the same day to leave naming out of scope.
  Rationale: The rename breaks queries that match the span name. Release 0.13.0.0 already
  changes trace shape, so doing it now means users adjust once instead of twice.
  Date: 2026-11-11

- Decision: Measurement is a separate first plan, and both core plans gate on it.
  Rationale: The requirement is no performance regression and no space leak. Neither can be
  shown without a tracing-enabled baseline, and none exists.
  Date: 2026-11-11

- Decision: One breaking core release (0.13.0.0) after EP-2, EP-3 and EP-7, before any adapter plan
  completes.
  Rationale: Adapters consume `shibuya-core` from Hackage; shipping the record change and the
  batch behaviour change together avoids two breaking releases.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)

Revision note (2026-11-12): resolved the review findings across the MasterPlan and children,
recorded the proposed correlation contract in ADR 0014, and retained explicit external
verification limits. Benchmark scope is unchanged.
