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
      at: 2026-11-12T23:23:05Z
      mode: "implement"
      note: "Implement correlation policy, process span helpers, gate and docs"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:42:29Z
      verdict: "changes-requested"
      note: "Resolve absent-header parentage and public helper ambient contract; corrected batch gate scope."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:51:06Z
      verdict: "comments"
      note: "Follow-up: planning findings resolved; document checks pass; dependency, adapter and runtime validation remain implementation prerequisites."
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
message's creation context. Creation-context parenting is optional for single messages; the
recommendation against that default applies when processing within another span.

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

- [x] M1 (2026-11-12): `Shibuya.Telemetry.Correlation` exists; `Adapter` has a `telemetry` field set to
  `defaultAdapterTelemetry` at every construction site in this repository; per-message spans with a
  creation context carry exactly one link; `cabal build all` and `cabal test shibuya-core` pass.
  Evidence: `cabal build all --enable-tests --enable-benchmarks` clean; all four `shibuya-core`
  suites and `shibuya-metrics-test` pass (340 and 104 examples).
- [x] M2 (2026-11-12): `LinkOnly` yields a root span in a new trace with the link, even when an ambient span
  is active; with tracing disabled no header is decoded; new tests in
  `shibuya-core/test/Shibuya/Telemetry/CorrelationSpec.hs` pass. Evidence: 28 examples, 0
  failures. Disabled-path decode removal is measured in M3.
- [x] M3 (2026-11-12): Performance and retention gate passed against the baseline commit, with the measured
  per-message cost of the link recorded in this plan; retention suite extended to both policies
  and passing. Evidence: allocation gate met (Surprises & Discoveries). The time gate was met on
  a quiet machine except one 100-message microbenchmark accepted as noise (Decision Log).
  Seven retention checks pass.
- [x] M4 (2026-11-12): User guide, capability document, changelog and ADR 0014 describe the policy; the
  parent MasterPlan's registry and Integration Points are updated. Evidence: "Parent or link"
  section in `docs/user/opentelemetry.md`; CAP-8 and its log updated and `okf validate --strict`
  passes; `0.13.0.0 — Unreleased` changelog entry; ADR 0014 Evidence section; version bump left
  to the release skill.


## Surprises & Discoveries

Review resolved (2026-11-12): the MasterPlan now matches this plan's no-header ambient
parentage exception. The public helper explicitly documents suppression of meaningful ambient
context with valid headers. Batch decoding remains plan 56 work.

- Record update without the constructor works under `NoFieldSelectors`: the spec uses
  `defaultAdapterTelemetry {traceCorrelation = LinkOnly}` and `t.traceCorrelation` from another
  module. A scratch module outside the package that writes `AdapterTelemetry LinkOnly` fails
  with "Illegal term-level use of the type constructor `AdapterTelemetry`". The
  `withTraceCorrelation` fallback was therefore not needed.
- Ten construction sites build `Adapter` positionally (`Adapter "name" source shutdown`), not
  with a record literal. Five are in `shibuya-core` tests and two in `shibuya-metrics`. The
  plan's grep for record syntax does not find them; the compiler does.
- `withProcessSpan` uses one `withEffToIO` for the context attachment and the span together. The
  old `ParentAndLink` path used two, one in `withExtractedContext` and one in `withSpan'`. The
  plan allowed at most the old two.

- M3 gate, 2026-11-12, against baseline `526ddb1` (EP-1's completion commit). Retention: all
  seven checks pass, covering single-serial Check A and Check B under both `ParentAndLink` and
  `LinkOnly`. Allocation, which is deterministic, meets the contract and improves it:
  - Every single-message path allocates about 208 bytes per message *less*. This includes
    `hot-path`, `handler-overhead`, `framework-overhead` and `concurrency-modes` serial; for
    example `hot-path/serial-noop-10000` went from 19,917,111 to 17,838,867. The most likely
    cause is the per-message action closure the old `withExtractedContext parentCtx $ ...`
    wrapper allocated, which `withProcessSpan` no longer builds.
  - The disabled-path decode is gone. `tracing/single-serial/disabled-headers` allocates
    17,815,460, the same as `disabled-noheaders` (17,816,921); the baseline was 23,352,054.
  - The cost of the link: `single-serial/enabled-headers` minus `enabled-noheaders` was 1,360
    bytes per message at baseline and is 1,151 now. The new one-element link list, `NewLink` and
    `SpanArguments` cost less than the second `withEffToIO` they replaced. `LinkOnly`
    (`enabled-headers-linkonly`, 94,466,964) allocates about 135 bytes per message less than
    `ParentAndLink`, because it builds no parent context.
  - Exceptions are all `Async`/`Ahead` cells with 1–5 ms handler delays in
    `concurrency-modes`: −165 KB to +290 KB per 100-message run, in both directions, across two
    runs. These cells' allocation depends on worker dispatch (see plan 30); their per-message
    code is the path that got cheaper everywhere else. `lifecycle/batch-size` (+0.2%) runs
    through the batch runner, which this plan does not change.
- M3 time gate, first three comparisons (2026-11-12): 15–48% slower times in `lifecycle/*`,
  `hot-path/async8` and `single-async8`, across a full run, a `--stdev 3` re-run and an
  order-swapped re-run. The unchanged batch path (`lifecycle/batch-size`) was among them, while
  allocation fell or stayed flat. Load average rose from 4.7 to 23 while another project's test
  suites, a VM and `mori` ran. The suite runs `+RTS -N` (36 capabilities). The parallel GC's
  stop-the-world barrier waits for the slowest capability, so concurrent, GC-heavy cells
  degrade most when other work holds some cores; serial cells moved only 2–3%.
- M3 time gate, rerun at load ≈4–7 (2026-11-12): every `lifecycle`, `hot-path`, `tracing`,
  `handler` and `concurrency` cell is within `--fail-if-slower 10`. One cell failed,
  `framework-overhead/comparison/100-msgs/shibuya-framework`: +22%, and +12% on the
  `--stdev 3` confirming re-run. It is accepted as noise (Decision Log). In the same confirming
  run its pure-streamly control `comparison/1000-msgs/streamly-baseline`, which contains no
  Shibuya code, failed at +17%. Its twin `processing/runWithMetrics-100` measures the same
  `runWithMetrics` call without in-measurement message construction and was unchanged
  (30.2 µs). Its own allocation fell from 319,008 to 298,269 bytes.


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

- Decision: Preserve the no-header ambient-parent exception and explicitly document the
  independent-processing contract of both public helpers.
  Rationale: With valid creation headers, `ParentAndLink` replaces ambient parentage with the producer
  and adds its link; `LinkOnly` clears ambient context and adds the producer link. Without usable
  headers, both policies preserve ambient parentage and emit no link, retaining existing behavior.
  Batches always clear ambient context. No path adds an ambient-context link. Direct callers of
  `withProcessSpan` and `withProcessSpanIO` accept this same contract: these helpers are for
  independent message processing and do not preserve a meaningful enclosing operation when
  valid creation headers exist. That deliberate limitation must be documented, not described
  as universally inapplicable to consumers.
  Date: 2026-11-12

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

- Decision: Accept the remaining time-gate failure,
  `framework-overhead/comparison/100-msgs/shibuya-framework` (+12% to +22%), as measurement
  noise and complete M3.
  Rationale: The cell builds its 100 messages inside the measured region. Its twin
  `processing/runWithMetrics-100`, which measures the same `runWithMetrics` call, is unchanged.
  Its allocation fell 7%. A pure-streamly control in the same group failed at +17% in the same
  run. This plan changes only per-message span construction, which got cheaper in every cell
  that isolates it. The user directed (2026-11-12) that time failures which disappear on a
  quiet machine be recorded as artifacts and the work continued.
  Date: 2026-11-12

- Decision: A message without `traceContext` behaves exactly as today under either policy.
  Rationale: With no creation context there is nothing to link or to parent. Leaving the
  ambient context untouched keeps this plan's behaviour change limited to messages that carry
  headers.
  Date: 2026-11-11


## Outcomes & Retrospective

Completed 2026-11-12. Every per-message processing span links to the producer's span when its
headers decode. Adapters declare `ParentAndLink` (the default) or `LinkOnly` through
`Adapter.telemetry`, a strict field holding an `AdapterTelemetry` record whose constructor is
hidden. `processOne` and external callers share `Shibuya.Telemetry.Process`. The interfaces
match the parent MasterPlan's Integration Points; `withTraceCorrelation` was not needed.

The change made processing cheaper rather than costlier. About 208 bytes per message
disappeared from every single-message path. The disabled path stopped decoding headers, about
350 bytes per message for messages with a `traceparent`. With headers and tracing enabled,
the link costs less than the second unlift it replaced. `ParentOnly` therefore stays
unnecessary, and the MasterPlan's two-policy decision stands.

Most of this plan's time went into the time gate. On a 36-core machine shared with other
workloads, the `+RTS -N` benchmark's concurrent cells were unreadable until load fell. The
remaining failure was accepted with evidence (Decision Log).

Friction: FRIC-2 (`docs/friction-log/2-benchmark-time-gate-is-unreadable-under-concurrent-machine-load.md`,
slowdown) is resolved by the load note in `shibuya-core-bench/README.md`.

ADR distillation: ADR 0014 now records the implemented interface, the evidence and the
non-recording-provider constraint. The load sensitivity of time gates is a benchmarking
practice, documented in the bench README rather than an ADR. ADR 0006 already says allocation
is the stricter signal.


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

The [messaging conventions](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/)
recommend creation-context links. Single-message processing may also use creation-context
parentage; the recommendation against that default applies within another span. Instrumentation
should document its choice and may offer configuration. This plan implements links and that
configuration. Adapter plans select defaults; `defaultAdapterTelemetry` uses `ParentAndLink`
for continuity. The public helpers deliberately omit ambient-context links as documented here.

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
- Either policy, message without headers: no links; parentage as before this plan. Exercise
  both an active ambient span and an empty context, including direct effect and IO helper calls.
- Either policy, malformed `traceparent`: same ambient-parent exception as absent headers.
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
- Single-message `disabled-headers` cells: allocation must not increase, and should decrease to match
  `disabled-noheaders` because headers are no longer decoded. If it does not, the short-circuit
  is not working. Batch header decoding is changed by plan 56, so batch cells must remain
  unchanged in this plan rather than satisfy the single-message decode-elimination criterion.
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
own trace under `LinkOnly` when headers decode. Document the no-header ambient-parent
exception and the public helper limitation: with valid headers neither policy preserves a
meaningful enclosing operation. Explain the qualified OTel parenting recommendation and the
deliberate omission of an ambient-context link. Correct the capability document
`docs/capabilities/opentelemetry-tracing.md`, which currently states that the producer's trace
always continues into the consumer. Add a `0.13.0.0` entry to `shibuya-core/CHANGELOG.md`
naming the breaking `Adapter` field, the new module, the added link, and the disabled-path
fix, and bump `version` in `shibuya-core/shibuya-core.cabal` only if the repository's release
process expects the bump before release (read `agents/skills/release/SKILL.md`; otherwise leave
the bump to the release). Update `docs/architecture/CORE_TYPES.md` where it lists `Adapter`.

Update [ADR 0014](../adr/0014-define-consumer-correlation-and-bounded-batch-link-accounting.md) with the implemented API,
measured cost and acceptance evidence, preserving its explicit no-header exception and public
helper limitation. EP-3 and EP-7 add batch and naming evidence later. Keep its status Proposed
until all planned behavior is implemented and accepted. Link this plan and plan 54 as evidence.

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
This plan does not release the package. Release requires this plan,
`docs/plans/56-link-every-batch-member-s-creation-context-from-the-batch-span.md` and
`docs/plans/60-name-process-spans-and-operations-per-the-messaging-conventions.md` all Complete.


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
-- body receives the sentinel span and no header is decoded. With valid headers
-- a meaningful ambient operation is neither parented nor linked: callers opt
-- into independent message processing by using this helper.
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
`creationLinkWith` and `consumerSpanArgsLinkedTo` and requires this plan Complete, including `withRootContext` from M2. The three
adapter plans (57, 58, 59 under `docs/plans/`) use `TraceCorrelation`, `AdapterTelemetry`,
`defaultAdapterTelemetry` and the `Adapter.telemetry` field. Outside this MasterPlan, Keiro
consumes `Shibuya.Telemetry.Process` (see the Decision Log); do not change those two signatures
after release without checking that consumer. Adapter implementation requires this plan
Complete and the core release published.

Revision note (2026-11-12): resolved the ambient-context contradiction by preserving the
no-header exception; documented the public helper limitation and sole ownership of the
root-context helper. ADR 0014 now holds the proposed contract.
