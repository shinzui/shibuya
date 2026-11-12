---
id: 55
slug: add-an-adapter-declared-trace-correlation-policy-to-single-message-processing
title: "Add an adapter-declared trace correlation policy to single-message processing"
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
      at: 2026-11-12T04:52:36Z
      mode: "update"
      note: "Export the processing-span function for Keiro"
---

# Add an adapter-declared trace correlation policy to single-message processing

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Shibuya wraps the processing of each message in an OpenTelemetry span. Today that span is
always a child of the span that produced the message, and it never records a *link*. A link is
OpenTelemetry's way for one span to point at another causally related span without joining its
trace. The OpenTelemetry messaging conventions say a processing span SHOULD link to the
message's creation context, and that making it a child is optional and not recommended as the
default.

After this change, every per-message processing span carries a link to the producer's span,
and each adapter states a policy: `ParentAndLink` (child of the producer, plus the link; one
connected trace, as today) or `LinkOnly` (a new root trace, related to the producer only by the
link). `LinkOnly` is for sources where joining the producer's trace is harmful: replayed event
streams, long-delayed or retried jobs, fan-out to many consumers, and deployments using
tail-based sampling.

Someone can see it working by running the test suite, where an in-memory span exporter shows,
for the same message, a child span with one link under `ParentAndLink` and a root span with a
different trace ID and one link under `LinkOnly`. The change must add no cost when tracing is
disabled and must not make a span keep message data alive; both are checked by benchmarks and
tests that already exist from the preceding plan.


## Progress

- [ ] M1: `Shibuya.Telemetry.Correlation` exists; `Adapter` has a `telemetry` field set to
  `defaultAdapterTelemetry` at every construction site in this repository; per-message spans with a
  creation context carry exactly one link; `cabal build all` and `cabal test shibuya-core` pass.
- [ ] M2: `LinkOnly` yields a root span in a new trace with the link, even when an ambient span
  is active; with tracing disabled no header is decoded; new tests in
  `shibuya-core/test/Shibuya/Telemetry/CorrelationSpec.hs` pass.
- [ ] M3: Performance and retention gate passed against the baseline commit, with the measured
  per-message cost of the link recorded in this plan; retention suite extended to both policies
  and passing.
- [ ] M4: User guide, capability document, changelog and a new ADR describe the policy; the
  parent MasterPlan's registry and Integration Points are updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The policy is declared by the adapter and read once per processor.
  Rationale: The right default is a property of the message source. A per-processor constant
  costs nothing per message. Adding a record field to `Adapter` is a breaking change, accepted
  before 1.0; the version becomes 0.13.0.0.
  Date: 2026-11-11

- Decision: `Adapter` gains one field, `telemetry :: !AdapterTelemetry`, and the policy is a
  field of that record. `AdapterTelemetry` is exported with its field but without its
  constructor and is built from `defaultAdapterTelemetry` by record update.
  Rationale: `Adapter` is constructed by record literal in three adapter repositories, so each
  field added to it costs a coordinated breaking release. Later telemetry options (for example
  a per-message rule that links only old or redelivered messages, or a switch for settle spans)
  can then be added as fields with defaults without touching `Adapter` or any adapter. Hiding
  the constructor is what makes such an addition non-breaking. The record adds no per-message
  cost because the runner projects the policy out of it once per processor.
  Date: 2026-11-11

- Decision: The link is passed in the span's creation arguments, not added afterwards.
  Rationale: Samplers and span processors only see what is present at creation, and the
  OpenTelemetry specification asks for links at creation for that reason.
  Date: 2026-11-11

- Decision: A processing span never takes the thread's ambient context as parent and never
  links to it. `ParentAndLink` replaces the ambient context with the creation context (as the
  code already does today); `LinkOnly` replaces it with an empty context.
  Rationale: The OpenTelemetry messaging conventions say that when an ambient context exists the
  processing span is by default its child with a link to the creation context, and that if the
  creation context is the parent the ambient context "SHOULD" be added as a link. Those rules
  describe an application handling a message in the middle of another operation, such as an
  HTTP request. Shibuya dispatches messages on its own processing threads, where the current
  context is only whatever the thread that started the application happened to have. Parenting
  or linking every message to that would hang all processing off an application-lifetime span.
  This is recorded as "not applicable" rather than conformance; state it in the ADR.
  Date: 2026-11-11

- Decision: Single-message links carry no attributes.
  Rationale: The conventions put per-message attributes on links only where one span accounts
  for several messages. A single-message span already carries `messaging.message.id` itself.
  The shared empty attribute map also keeps the link's cost minimal.
  Date: 2026-11-11

- Decision: The construction of the processing span (decode once, link, parent or root by
  policy, Consumer kind) is exported as `Shibuya.Telemetry.Process.withProcessSpan`, with an
  `IO` form `withProcessSpanIO`, and `processOne` itself is built on it.
  Rationale: Two downstream users open this span outside Shibuya's runner. `keiro-pgmq`'s
  bounded drain copies it by hand today, and Keiro's own decision record notes that the copy
  can drift silently; Keiro's process managers and routers drain an adapter stream directly and
  have no processing span at all. Both are planned to call this function
  (`mori://shinzui/keiro/masterplans/47-trace-context-propagation-and-span-correlation-across-keiro-durable-boundaries`).
  With one implementation, a later change to the link or parent rule reaches every user. The
  function sets no attributes; those remain the caller's. It must add no cost to `processOne`,
  which the Milestone 3 gate checks.
  Date: 2026-11-11

- Decision: A message without `traceContext` behaves exactly as today under either policy.
  Rationale: With no creation context there is nothing to link or to parent. Leaving the
  ambient context untouched keeps this plan's behaviour change limited to messages that carry
  headers.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan is the second child of
`docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md`. It depends on
`docs/plans/54-establish-tracing-enabled-performance-and-retention-baselines.md` being complete:
that plan added the benchmark group `tracing` to `shibuya-core-bench` and the test suite
`shibuya-core-trace-retention-test`, and its last commit is the baseline this plan measures
against. If `shibuya-core-bench/bench/Bench/Tracing.hs` or `shibuya-core/test-retention/` does
not exist, stop: the prerequisite is not met.

Shibuya is a Haskell queue-processing framework; the library package is `shibuya-core`. The
pieces that matter here:

`shibuya-core/src/Shibuya/Adapter.hs` defines the adapter record, the interface a queue backend
implements:

```haskell
data Adapter es msg = Adapter
  { adapterName :: !Text,
    source :: Stream (Eff es) (Ingested es msg),
    shutdown :: Eff es ()
  }
```

It is constructed with record syntax in about three dozen places in this repository (mock
adapters in `shibuya-core/src/Shibuya/Adapter/Mock.hs`, tests under `shibuya-core/test/`,
`shibuya-core/test-gc/`, `shibuya-core/test-retention/`, the benchmarks, `shibuya-example`,
`shibuya-metrics`). Find them with `grep -rn "Adapter$\|Adapter {" --include='*.hs' .`.

`shibuya-core/src/Shibuya/Core/Types.hs` defines `Envelope`, whose field
`traceContext :: Maybe TraceHeaders` carries the W3C `traceparent`/`tracestate` header pairs
the adapter extracted from the incoming message. The "creation context" of a message is the
span identity encoded in those headers.

`shibuya-core/src/Shibuya/Telemetry/Effect.hs` defines the `Tracing` effect: `runTracing`,
`runTracingNoop`, `withSpan'` (opens a span via `OpenTelemetry.Trace.Core.inSpan'` and passes
the handle; when disabled passes a shared sentinel span and does nothing else),
`isTracingEnabled`, and `withExtractedContext :: Maybe SpanContext -> Eff es a -> Eff es a`,
which for `Just ctx` attaches a fresh context containing only that span as the thread's current
OpenTelemetry context for the duration of the action, and for `Nothing` runs the action
unchanged. Note its clause order: it matches on the `Maybe` first and checks the enabled flag
second.

`shibuya-core/src/Shibuya/Telemetry/Propagation.hs` has
`extractTraceContext :: TraceHeaders -> Maybe SpanContext`, the W3C decoder.

`shibuya-core/src/Shibuya/Telemetry/Semantic.hs` has `consumerSpanArgs`, a constant
`SpanArguments` with `kind = Consumer`, empty attributes, `links = []`.

`shibuya-core/src/Shibuya/Internal/Runner/Supervised.hs` is the single-message runner.
`runIngesterAndProcessor` has the `adapter` in scope and calls `processUntilDrained`, which
hoists per-processor constants (`spanName`, `constantFrameworkAttrs`) and then calls
`processOne` once per message. `processOne` begins:

```haskell
let parentCtx = ingested.envelope.traceContext >>= extractTraceContext
withExtractedContext parentCtx $
  withSpan' spanName consumerSpanArgs $ \traceSpan -> do ...
```

Three consequences of the current code matter. First, there is never a link. Second, because
`withExtractedContext` matches on `parentCtx` before checking the enabled flag, a message with
headers has them decoded even under `runTracingNoop`; the baseline benchmark cells
`tracing/*/disabled-headers` versus `disabled-noheaders` show the cost. Third, when
`parentCtx` is `Nothing` the thread's ambient context is left in place; on the unsupervised
runner path processing runs on the caller's thread, so an ambient span can exist.

From `hs-opentelemetry-api` 1.0 (`OpenTelemetry.Trace.Core`): `NewLink { linkContext ::
!SpanContext, linkAttributes :: AttributeMap }`, `SpanArguments { kind, attributes, links ::
[NewLink], startTime }`. `inSpan'` freezes the supplied links into the span at creation. The
thread-local context API is `OpenTelemetry.Context.ThreadLocal` (`attachContext`,
`detachContext`, `getContext`) with `OpenTelemetry.Context.empty` and `insertSpan`. Locate the
library source with `mori registry show iand675/hs-opentelemetry --full` and read it there
rather than guessing.

What the OpenTelemetry messaging conventions say (the document
`docs/messaging/messaging-spans.md` in `open-telemetry/semantic-conventions`, status
Development, read in full on 2026-11-11), in the sentences that govern this plan: "For each
message it accounts for, the "Process" or "Receive" span SHOULD link to the message's creation
context."; "Exclusively for single messages scenarios, the "Process" span MAY use the message's
creation context as its parent"; "It is NOT RECOMMENDED to use the message creation context as
the parent of "Process" spans (by default)"; "Instrumentations SHOULD document whether they use
the message creation context as a parent for "Process" spans" and "MAY provide configuration
options allowing users to control this behavior." This plan implements the link and the
configuration. Which policy is the default is chosen per adapter in the adapter plans.
`defaultAdapterTelemetry` uses `ParentAndLink`, so an adapter that states nothing keeps the
trace shape it has today plus the link.

Relevant ADRs.
[ADR 0012](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md):
adapters supply incoming context, the framework owns the Consumer span, exactly one Consumer
span per processed message, and disabled tracing uses a shared sentinel with no per-message
work. This plan keeps all of that and adds a declared policy on the adapter side.
[ADR 0013](../adr/0013-let-adapters-supersede-a-delivery-before-its-handler-runs.md): a
superseded delivery still opens the processing span, records an acknowledgement event with value
`superseded`, and ends successfully. That path runs inside the span this plan modifies and must
keep working under both policies.
[ADR 0006](../adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md):
an allocation increase is a regression even when time is within noise.

The performance and retention contract this plan must satisfy, from the parent MasterPlan:

1. Under `runTracingNoop` nothing new is allocated per message and no header is decoded. The
   policy is read once per processor.
2. Enabled, message without `traceContext`: behaviour and cost unchanged.
3. Enabled, message with `traceContext`: the added cost is one link, a bounded constant.
4. Nothing reachable from a span may reference the `Ingested`, the `Envelope`, the payload, or
   an unevaluated thunk over them. The link holds only an evaluated `SpanContext`, and the link
   list is fully evaluated before the span is created.
5. Heap residency under sustained processing stays flat.


## Plan of Work

### Milestone 1: the type, the field, and the link under the existing parent

Create `shibuya-core/src/Shibuya/Telemetry/Correlation.hs` and add it to `exposed-modules` in
`shibuya-core/shibuya-core.cabal`. It defines the policy type and the link helpers given in
Interfaces and Dependencies. Re-export `TraceCorrelation (..)` from `Shibuya.Adapter` and from
`Shibuya.Telemetry` so adapter authors need one import.

`creationLinkWith` decodes headers with `extractTraceContext` and, on success, returns a
`NewLink` carrying the supplied attribute map; `creationLink` is `creationLinkWith` applied to
the shared empty map. The single-message path uses `creationLink`; `creationLinkWith` exists for
the batch plan, which labels each link with its member's message identifier. Both return a
`NewLink` whose context has been forced (`linkContext` is a strict field; evaluate the `NewLink`
itself to weak head normal form before returning it inside `Just`, for instance with a bang
pattern). `creationLink`'s attributes are `HashMap.empty`, a shared constant, so it allocates no
map. Neither may capture the header list in its result.

Define `AdapterTelemetry` and `defaultAdapterTelemetry` in the same module as given in
Interfaces and Dependencies. Export the type as `AdapterTelemetry (traceCorrelation)`, that is,
with its field and without its constructor, so that record update and field access work from
other modules but construction goes through the default. The repository enables
`NoFieldSelectors` and `OverloadedRecordDot`; confirm in a small test module outside the
defining module that `defaultAdapterTelemetry {traceCorrelation = LinkOnly}` and
`t.traceCorrelation` compile and that `AdapterTelemetry LinkOnly` does not. If GHC's record
update rules prevent update without the constructor in scope, provide
`withTraceCorrelation :: TraceCorrelation -> AdapterTelemetry -> AdapterTelemetry` instead,
keep the constructor hidden, and record the change here and in the parent MasterPlan's
Integration Points. Re-export the type, its field and the default from `Shibuya.Adapter` and
`Shibuya.Telemetry`.

Add `telemetry :: !AdapterTelemetry` to `Adapter`. Update every construction site in the
repository to set `defaultAdapterTelemetry`. The mock adapter constructors in
`Shibuya/Adapter/Mock.hs` keep their signatures and set the default; do not add a parameter
there. A test that needs `LinkOnly` overrides the adapter's `telemetry` field with record
update.

Thread the policy to the hot loop as a per-processor constant: `runIngesterAndProcessor` reads
`adapter.telemetry.traceCorrelation` and passes it to `processUntilDrained`, which passes it to
`processOne` alongside `spanName`. Do not read it from the adapter per message.

In `processOne`, when tracing is enabled and the message has a decodable creation context, pass
span arguments carrying that one link; keep the parent attachment as it is. Messages without
context keep using the shared `consumerSpanArgs` constant, so that path allocates nothing new.
Decode the headers once and use the result for both the parent and the link.

At the end of M1 the only observable change is the extra link. Update existing telemetry tests
that assert an empty link list, if any.

### Milestone 2: `LinkOnly` and the disabled short-circuit

Restructure the start of `processOne` so the order of decisions is: is tracing enabled; if not,
run the body with `withSpan'` exactly as the disabled path does today and touch nothing else
(no access to `traceContext`). If enabled, decode `traceContext` once. With no context, proceed
as today. With a context, build the linked arguments, then by policy either attach the creation
context as parent (`ParentAndLink`, today's `withExtractedContext`) or attach an *empty* context
(`LinkOnly`) before opening the span, restoring the previous context afterwards.

Put that sequence in a new public module, `shibuya-core/src/Shibuya/Telemetry/Process.hs`
(add it to `exposed-modules`), as `withProcessSpan`, and make `processOne` call it; the
signature is in Interfaces and Dependencies. It takes the policy, the full span name and the
message's trace headers, and passes the span to its body; it sets no attributes and records no
outcome. Mark it `INLINE` or otherwise confirm in Milestone 3 that `processOne` compiles to the
same code as an inlined version. Provide `withProcessSpanIO` in the same module for callers that
hold a plain `Tracer` and are not in an effect stack with `Tracing`: it performs the same steps
directly against the OpenTelemetry API and always behaves as enabled. Implement the shared
decision logic once and have both functions use it.

Add the empty-context operation to `Shibuya.Telemetry.Effect` as `withRootContext`, implemented
like `withExtractedContext`'s `Just` branch but attaching `Ctx.empty`. It must use the same
bracket so the previous context is restored on normal exit, exception, and asynchronous
cancellation. Do not add a second `withEffToIO` per message beyond what the `ParentAndLink`
path already performs: one for the context attachment and one inside `withSpan'`.

Add `shibuya-core/test/Shibuya/Telemetry/CorrelationSpec.hs`, registered in the test suite's
module list, using the in-memory exporter in the same way as the neighbouring specs. Cases:

- `ParentAndLink`, message with headers: one Consumer span whose trace ID equals the producer's,
  whose parent span ID equals the producer's span ID, and whose links are exactly one link to
  the producer's trace ID and span ID.
- `LinkOnly`, same message: one Consumer span with no parent, a trace ID different from the
  producer's, and the same single link.
- `LinkOnly` with an ambient span active on the calling thread (use the unsupervised runner
  path, or wrap the run in an outer span): the Consumer span is still a root, and after
  processing the ambient span is still the thread's current span.
- Either policy, message without headers: no links; parentage as before this plan.
- Either policy, malformed `traceparent`: treated as no context.
- `LinkOnly` followed by `currentTraceHeaders` inside the handler: the returned `traceparent`
  names the new trace and the Consumer span, not the producer.
- A superseded delivery (ADR 0013) under `LinkOnly`: the span is created, carries the link, and
  ends successfully with the `superseded` event.
- Disabled tracing with headers under both policies: the handler runs and nothing is exported.
- `withProcessSpan` and `withProcessSpanIO` called directly, outside the runner, each produce
  the same span shape as `processOne` for both policies (same kind, name, link, parent), and
  `withProcessSpan` under `runTracingNoop` passes the sentinel span and exports nothing.
- `creationLink` unit tests: valid header, valid with `tracestate`, missing, malformed; and
  `creationLinkWith` returns the supplied attributes on the link.

### Milestone 3: performance and retention gate

Extend `shibuya-core-bench/bench/Bench/Tracing.hs` with `enabled-headers-linkonly` cells for
`single-serial` and `single-async8` (an adapter with the field overridden). Do not rename
existing cells.

Capture the baseline from a worktree at the last commit of plan 54 and compare, as shown in
Concrete Steps. Read the results against the contract:

- `disabled-noheaders` cells: no slower beyond noise, identical allocation.
- `disabled-headers` cells: allocation must not increase, and should decrease to match
  `disabled-noheaders` because headers are no longer decoded. If it does not, the short-circuit
  is not working.
- `enabled-noheaders` cells: no slower beyond noise, identical allocation.
- `enabled-headers` cells: an allocation increase is expected. Compute bytes per message
  (difference in `allocated` divided by 10,000) and record it in Surprises & Discoveries with
  what it consists of. The time gate still applies.
- The pre-existing groups (`hot-path`, `handler`, `concurrency`, `framework`) must show no
  allocation change. Run the whole benchmark once without the `-p` filter to confirm.

If an `enabled-headers` cell fails `--fail-if-slower 10` after a confirming re-run with
`--stdev 3`, stop and decide. First look for avoidable cost (a second decode, an unshared
attribute map, an extra unlift, a list built lazily). If the remaining cost is intrinsic to the
link, record the numbers and take a decision in the Decision Log and the MasterPlan: the
candidate is a third policy, `ParentOnly`, reproducing today's behaviour, as the default for
adapters that keep the parent. Do not proceed to M4 with a failing gate.

Extend `shibuya-core/test-retention/Main.hs`: run Check A (finished spans do not keep payloads
alive) and Check B (live bytes flat) for single-message processing under both `ParentAndLink`
and `LinkOnly`. All must pass. Then run the three existing suites; the garbage-collection suites
must be unaffected.

### Milestone 4: documentation and decision record

Update `docs/user/opentelemetry.md`: in the "Distributed tracing across hops" section add a
subsection "Parent or link" explaining the two policies, what each looks like in a trace
backend, when to choose `LinkOnly`, that the default comes from the adapter and is changed in
the adapter's configuration, that a link-only consumer trace is sampled independently of the
producer's, that `currentTraceHeaders` inside a handler propagates the processing span's
own trace under `LinkOnly`, and that the processing span never joins or links whatever span was
current on the thread that started the application. Say plainly which behaviour the messaging
conventions recommend by default (link only), so that the conventions' requirement to document
the choice is met. Correct the capability document
`docs/capabilities/opentelemetry-tracing.md`, which currently states that the producer's trace
always continues into the consumer. Add a `0.13.0.0` entry to `shibuya-core/CHANGELOG.md`
naming the breaking `Adapter` field, the new module, the added link, and the disabled-path
fix, and bump `version` in `shibuya-core/shibuya-core.cabal` only if the repository's release
process expects the bump before release (read `agents/skills/release/SKILL.md`; otherwise leave
the bump to the release). Update `docs/architecture/CORE_TYPES.md` where it lists `Adapter`.

Create a new ADR in `docs/adr/` following the existing plain convention (numbered filename,
`Status`, `Date`, `Context`, `Decision`, `Consequences`, `Evidence`; next number after 0013).
Record: the link is always emitted at span creation; parenthood is an adapter-declared policy;
the policy lives on `Adapter` and why not on the processor; the retention rule for links; the
measured cost; and the standing of the design against the messaging conventions, quoting the
sentences above: the link and the configurability conform, a `ParentAndLink` adapter default is
a deliberate departure from the recommended default, the ambient-context rules are treated as
not applicable (with the reasoning from this plan's Decision Log), and the known gaps: span
name order and the Required `messaging.operation.name` (closed later in the same release by
`docs/plans/60-name-process-spans-and-operations-per-the-messaging-conventions.md`, which
updates the ADR), and "Settle" spans and extraction through the configured propagator (left
alone). Link this plan and plan 54 as evidence.

In the parent MasterPlan, mark this plan Complete in the registry, update Progress, and if the
constructor set or helper signatures differ from its Integration Points section, correct that
section, because three adapter plans consume it.


## Concrete Steps

All commands run from the repository root inside the nix devShell.

After each milestone:

```bash
nix fmt
cabal build all
cabal test shibuya-core
cabal test shibuya-metrics
```

Run only the new spec while iterating:

```bash
cabal test shibuya-core:test:shibuya-core-test --test-options='--match "Correlation"'
```

Performance gate (M3). `<baseline-commit>` is the last commit of plan 54; find it with
`git log --oneline -- docs/plans/54-establish-tracing-enabled-performance-and-retention-baselines.md`.

```bash
git worktree add /tmp/shibuya-tracing-baseline <baseline-commit>
( cd /tmp/shibuya-tracing-baseline && \
  cabal bench shibuya-core-bench \
    --benchmark-options="--stdev 5 --timeout 120 --csv /tmp/shibuya-tracing-baseline.csv" )
cabal bench shibuya-core-bench \
  --benchmark-options="--stdev 5 --timeout 120 --baseline /tmp/shibuya-tracing-baseline.csv --fail-if-slower 10 --csv /tmp/shibuya-tracing-after.csv"
git worktree remove /tmp/shibuya-tracing-baseline
```

A passing run ends with every benchmark `OK` and exit status 0. New cells have no baseline row
and are reported without a comparison; that is expected. Compare the `allocated` column of the
two CSVs cell by cell.

Retention gate (M3):

```bash
cabal test shibuya-core:test:shibuya-core-trace-retention-test --test-show-details=direct
```

Expected additional lines:

```text
PASS: single/ParentAndLink: finished spans do not retain payloads
PASS: single/LinkOnly: finished spans do not retain payloads
PASS: single-serial/LinkOnly: live bytes flat
```


## Validation and Acceptance

Behaviour. The `CorrelationSpec` cases listed in Milestone 2 pass. In particular, for one
message with a known `traceparent`, the exported span under `ParentAndLink` has that trace ID,
that parent, and one link; under `LinkOnly` it has a different trace ID, no parent, and the same
link. Before this plan the first case fails on the link assertion and the second cannot be
expressed.

Compatibility. Every other existing test in `shibuya-core` and `shibuya-metrics` passes
unchanged apart from added `telemetry = defaultAdapterTelemetry` fields and any assertion that
previously required an empty link list.

Performance. The benchmark comparison exits 0. The disabled and no-header cells and all
pre-existing groups show no allocation increase. The measured per-message link cost for
`enabled-headers` is written in this plan with its explanation.

Space. The retention suite passes for both policies: after processing, payloads are collected
while their spans remain held by the exporter, and live bytes after 200,000 messages are within
the suite's margin of live bytes after 20,000.

Documentation. A reader of `docs/user/opentelemetry.md` can tell which policy their adapter
uses by default, how to change it, and what changes in their trace backend.


## Idempotence and Recovery

Milestone 1 is a mechanical, compiler-guided change: after adding the field, `cabal build all`
lists every construction site that needs it; repeat until clean. All edits are ordinary source
changes recoverable with git. The benchmark worktree can be removed and recreated freely. If
the gate fails, the working tree is left as is for investigation; nothing has been published.
This plan does not release the package; the release happens once, after the batch plan
(`docs/plans/56-link-every-batch-member-s-creation-context-from-the-batch-span.md`), as the
parent MasterPlan describes.


## Interfaces and Dependencies

Prerequisite: `docs/plans/54-establish-tracing-enabled-performance-and-retention-baselines.md`
Complete.

Depends on `hs-opentelemetry-api` `^>=1.0` and `hs-opentelemetry-propagator-w3c` `^>=1.0`,
already dependencies of `shibuya-core`. No new package dependency.

New public module `Shibuya.Telemetry.Correlation` in `shibuya-core`:

```haskell
module Shibuya.Telemetry.Correlation
  ( TraceCorrelation (..),
    AdapterTelemetry (traceCorrelation),
    defaultAdapterTelemetry,
    creationLink,
    creationLinkWith,
    consumerSpanArgsLinkedTo,
  )
where

-- | How a processing span relates to the span that created the message.
data TraceCorrelation
  = -- | Child of the creation context, and linked to it. One connected trace.
    ParentAndLink
  | -- | A new root trace, related to the creation context only by a link.
    LinkOnly
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

-- | Decode trace headers into a link to the message's creation context.
-- 'Nothing' when the headers are absent or malformed. The result holds an
-- evaluated 'SpanContext' and no reference to the header list.
creationLink :: TraceHeaders -> Maybe NewLink

-- | As 'creationLink', with attributes describing the linked message. The
-- caller supplies an already evaluated map.
creationLinkWith :: AttributeMap -> TraceHeaders -> Maybe NewLink

-- | Consumer-kind span arguments carrying the given links. The list must be
-- fully evaluated by the caller.
consumerSpanArgsLinkedTo :: [NewLink] -> SpanArguments
```

Changed public record in `Shibuya.Adapter`:

```haskell
data Adapter es msg = Adapter
  { adapterName :: !Text,
    source :: Stream (Eff es) (Ingested es msg),
    shutdown :: Eff es (),
    telemetry :: !AdapterTelemetry
  }
```

New function in `Shibuya.Telemetry.Effect`:

```haskell
-- | Run an action with an empty OpenTelemetry context attached, so a span
-- opened inside it is a root. The previous context is restored afterwards.
-- A no-op when tracing is disabled.
withRootContext :: (Tracing :> es, IOE :> es) => Eff es a -> Eff es a
```

New public module `Shibuya.Telemetry.Process`:

```haskell
-- | Open the Consumer-kind processing span for one message. Linked to the
-- creation context in the headers when one decodes; a child of it under
-- 'ParentAndLink'; a root under 'LinkOnly'. Without usable headers the span
-- is opened in the ambient context, as before. With tracing disabled the
-- body receives the sentinel span and no header is decoded.
withProcessSpan ::
  (Tracing :> es, IOE :> es) =>
  TraceCorrelation ->
  -- | full span name, e.g. @processSpanName destination@
  Text ->
  Maybe TraceHeaders ->
  (Span -> Eff es a) ->
  Eff es a

-- | The same span for callers holding a 'Tracer' outside the 'Tracing' effect.
withProcessSpanIO ::
  Tracer -> TraceCorrelation -> Text -> Maybe TraceHeaders -> (Span -> IO a) -> IO a
```

`Shibuya.Telemetry.Semantic.consumerSpanArgs` remains exported and unchanged.

Consumers of these interfaces: the batch plan
(`docs/plans/56-link-every-batch-member-s-creation-context-from-the-batch-span.md`) uses
`creationLinkWith` and `consumerSpanArgsLinkedTo` and needs only Milestone 1 accepted. The three
adapter plans (57, 58, 59 under `docs/plans/`) use `TraceCorrelation`, `AdapterTelemetry`,
`defaultAdapterTelemetry` and the `Adapter.telemetry` field. Outside this MasterPlan, Keiro
consumes `Shibuya.Telemetry.Process` (see the Decision Log); do not change those two signatures
after release without checking that consumer
and need this plan Complete and `shibuya-core` 0.13.0.0 published.
