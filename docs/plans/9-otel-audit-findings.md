---
id: 9
slug: otel-audit-findings
title: "OpenTelemetry API audit — findings (plan 9, M1)"
kind: exec-plan
created_at: 2026-05-05T14:24:37Z
---


# OpenTelemetry API audit — findings (plan 9, M1)

This document is the read-only deliverable of Milestone 1 of
`docs/plans/9-audit-and-improve-opentelemetry-api.md`. It surveys the
OpenTelemetry surface exposed by `shibuya-core` and the two real
adapters (`shibuya-pgmq-adapter`, `shibuya-kafka-adapter`), enumerates
every issue worth acting on, ranks each P0/P1/P2, and proposes a
concrete fix per finding. M2 and M3 of plan 9 read this document to
decide what to implement.

The audit considers four separable concerns (per plan 9 Decision Log
entry 3):

-   **(A)** the `Tracing` effect surface itself,
-   **(B)** the per-message span shape contract between the framework
    and adapters,
-   **(C)** the parent-context propagation contract via
    `Envelope.traceContext`,
-   **(D)** the producer/DLQ-side propagation contract.

Plan 2 fixed (B) at the attribute level for shibuya-core; plan 10
(kafka-side) fixed (B) for the kafka adapter's `traced` wrapper. (C)
on consume is fully wired in both adapters and `processOne`. (D) is
the largest remaining hole. The other open ground is on (B) at the
*ownership* level — who opens the per-message span and who contributes
attributes to it.


## Triage table

| ID | Title | Bucket | Severity | Status |
|----|-------|--------|----------|--------|
| F1 | `traced` + `runApp` emits two duplicate Consumer spans per message | B | **P0** | shibuya-core 0.5.0.0 fix landed (2026-05-05). Adapter-side migration pending Hackage publication. |
| F2 | Kafka-typed attributes only land on the adapter span, not the framework's | B | **P1** | Subsumed by F1's fix. |
| F3 | pgmq DLQ writes carry the original producer's `traceparent`, not the failing consumer's | D | **P1** | Open. |
| F4 | `runApp` does not bracket tracing initialization; `TracingConfig` is dead code | A | **P1** | Open. |
| F5 | `injectTraceContext` is exported but used by no in-tree adapter | D | **P2** | Open. Will land alongside F3's `currentTraceHeaders`. |
| F6 | `runTracingNoop` allocates a `TracerProvider` and `Tracer` per call | A | **P2** | Open. |
| F7 | `withSpan'` synthesises a misleading all-zero `FrozenSpan` when disabled | A | **P2** | Open. |
| F8 | Ingester poll-loop and adapter shutdown are invisible in traces | B | **P2** | Open. |

S4 (the suspicion that pgmq lacks a `traced` module) is **refuted as a
distinct finding**: the absence is intentional (pgmq has no broker-
specific typed attribute conventions worth the asymmetry) and is
absorbed by F2 — once attribute contribution moves off `traced` and
onto the framework span, the `traced` module itself is redundant and
the asymmetry disappears.


## Findings

### Finding F1: `traced` + `runApp` emits two duplicate Consumer spans per message

Bucket: B (per-message span shape).
Severity: **P0**.
Evidence:
`shibuya-core/src/Shibuya/Runner/Supervised.hs:374-375` and
`shibuya-core/src/Shibuya/Runner/Supervised.hs:411-412` — `processOne`
opens `withSpan' (processSpanName pidText) consumerSpanArgs` whose body
calls both `handler ingested` and `ingested.ack.finalize decision`.
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs:84-101` —
`traced` rewrites `Ingested.ack` so its `finalize` runs inside another
`withExtractedContext parentCtx $ withSpan' (processSpanName
topicName) consumerSpanArgs`.

What it is: under `runApp`, the framework's `processOne` opens span A
(Consumer kind, name `"<processorId> process"`, parented from the
envelope's `traceContext`). Inside A's body, the handler runs and
then `ack.finalize` is called. If the `AckHandle` was wrapped by
`Shibuya.Adapter.Kafka.Tracing.traced`, that finalize call enters a
*second* `withExtractedContext parentCtx` block, which (via
`Ctx.attachContext (Ctx.insertSpan parentSpan Ctx.empty)` at
`shibuya-core/src/Shibuya/Telemetry/Effect.hs:281-286`) replaces the
active thread-local context with one containing only the parent span
from the headers — span A is no longer active. `withSpan'` then
opens span B parented to the headers' parent. The result is two
Consumer-kind spans for the same physical message, **siblings** under
the same root rather than nested. A carries the framework's
`messaging.*` and `shibuya.*` attributes; B carries the spec-aligned
`messaging.*` set plus the Kafka-typed
`messaging.kafka.destination.partition` /
`messaging.kafka.message.offset`. Neither span has the union.

Why it matters: two consumer-span entries per message inflate
trace-store cost, halve the apparent throughput in span-rate dashboards,
and force an operator to cross-reference two siblings to reconstruct
what one message did. The Kafka adapter's existing demo
(`shibuya-kafka-adapter/shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs:96-108`)
hides this because it folds the source stream by hand and never
passes through `runApp`/`processOne`; the `traced` test
(`shibuya-kafka-adapter/shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs:138-161`)
does the same. So the bug is real but unobserved by today's CI.

Proposed fix: invert the ownership. Add a new optional field
`attributes :: !(Maybe (HashMap Text Attribute))` to
`shibuya-core/src/Shibuya/Core/Types.hs::Envelope`. The adapter's
`Convert.hs` populates it at envelope-construction time with whatever
broker-specific typed attributes the adapter has (Kafka:
`messaging.kafka.destination.partition`,
`messaging.kafka.message.offset`; pgmq: empty). `processOne` reads
the field after opening its span and calls `addAttributes traceSpan
attrs`. The Kafka adapter's `Shibuya.Adapter.Kafka.Tracing` module
then either deletes outright (its only job becomes attribute
contribution, which has moved to `Convert.hs`) or shrinks to a thin
helper that constructs the attribute hashmap from a Kafka
`ConsumerRecord`. The framework owns the span; the adapter contributes
data. Tests in M2 must run a `runApp`-style scenario through both
adapters and assert exactly one Consumer span per message, carrying
the union of spec-aligned and adapter-specific attributes.

Alternatives considered: (1) document `traced` as mutually exclusive
with `runApp` — works but sweeps the underlying ownership confusion
under a Haddock note and leaves a footgun for any future adapter
author. (2) have `traced` lookup the active span via
`OpenTelemetry.Context.lookupSpan` and short-circuit if one is
present — brittle, depends on span identity rather than role, and
silently does nothing in the very setup the user paid to import. The
attribute-hook fix is the only one that makes the adapter's role
honest.

Prior decisions:
`shibuya-kafka-adapter/docs/plans/9-add-shibuya-kafka-tracing-module.md`
introduced `traced` to remove ~25 lines of per-handler boilerplate in
`OtelDemo.hs`. That goal is preserved by the proposed fix — the
adapter author's call site goes from "wrap the source stream with
`traced`" to "do nothing extra; envelopes already carry the right
attributes." Plan 10 (kafka attribute alignment) targeted the
*content* of `traced`'s span; this audit targets its *existence*.


### Finding F2: Kafka-typed attributes only land on the adapter span, not the framework's

Bucket: B (per-message span shape).
Severity: **P1** (subsumed by F1 if F1's fix lands; otherwise P1 on its
own).
Evidence: the typed Kafka attribute keys
`messaging.kafka.destination.partition` and
`messaging.kafka.message.offset` are emitted only at
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs:123-139`
(the `populateAttrs` body). They are *not* set anywhere in
`shibuya-core/src/Shibuya/Runner/Supervised.hs::processOne`, which
sets only `messaging.system="shibuya"`, `messaging.destination.name`,
`messaging.operation`, `messaging.message.id`, and `shibuya.partition`
(at lines 378-386).

What it is: a user who follows the Quick Start in
`shibuya-core/src/Shibuya/Telemetry.hs:5-23` (which never mentions
`Shibuya.Adapter.Kafka.Tracing`) and runs a Kafka adapter under
`runApp` sees the `processOne` span without any
`messaging.kafka.*` keys. The framework's `shibuya.partition` carries
the partition id as a string, which is at least better than nothing,
but the offset is lost outright. A user who *does* import `traced`
gets the typed keys on the inner sibling span (F1) and not on
`processOne`'s span. Either way the desirable end state — one span
with the full attribute set — is unreachable today.

Why it matters: the typed Kafka keys are `Int64` on the wire, so
operators who run Jaeger queries like
`messaging.kafka.message.offset >= 12345` get one answer with the
adapter's tracing on and a different (no-results) answer without it.
Cross-cutting these against
`messaging.system="shibuya"` filters out the kafka spans entirely
because today only the framework span carries `messaging.system` and
it always says `"shibuya"`, never `"kafka"`. In other words, the
*system* attribute on the only span the user reliably gets lies about
which broker is in use.

Proposed fix: same as F1 — once `Envelope.attributes` is populated by
the adapter's `Convert.hs`, the framework's `processOne` adds
adapter-supplied attributes to its own span, and the kafka adapter
sets `messaging.system="kafka"` (overriding the framework's default
`"shibuya"`) plus the typed kafka keys. F1 and F2 share the fix.

Alternatives considered: have `processOne` emit
`messaging.system="shibuya"` *only* when the adapter does not
contribute its own — this is what the attribute-merge order naturally
gives you (adapter-supplied attrs override framework defaults). No
explicit precedence rule needed if the framework runs `addAttribute`
for its defaults *before* `addAttributes` from `Envelope.attributes`.

Prior decisions: plan 2
(`docs/plans/2-align-opentelemetry-semantic-conventions.md`) fixed the
*set* of attribute keys; plan 10
(`shibuya-kafka-adapter/docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md`)
fixed the wire names of the kafka-specific keys. Neither plan touched
which span carries which keys.


### Finding F3: pgmq DLQ writes carry the original producer's `traceparent`, not the failing consumer's

Bucket: D (producer/DLQ-side propagation).
Severity: **P1**.
Evidence:
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:201-252`.
The `AckDeadLetter` branch of `mkAckHandle` constructs a
`SendMessageWithHeaders` whose `messageHeaders = Pgmq.MessageHeaders
headers`, where `headers` is `msg.headers` — the original message's
unmodified header map. No `traceparent` is replaced or augmented with
the failing consumer's current trace context. Same in the
`TopicRoute` branch (lines 231-250) and same when `msg.headers ==
Nothing` (lines 223-230, 243-250) — those fall back to plain
`sendMessage` / `sendTopic` with no headers at all, dropping the
producer's trace context too.

What it is: when a consumer hands a poison-pill verdict
(`AckDeadLetter`) to the adapter, the message is rewritten and
forwarded to the DLQ. A downstream operator who follows the DLQ
message's trace sees a span tree rooted at the *original producer*
that put the message on the main queue, with no link to the
*consumer* whose handler gave up on it. The failure event lives only
on `processOne`'s span (set via `setStatus traceSpan $ OTel.Error
…`), which sits on the main-queue trace, not on the DLQ-message
trace. A consumer of the DLQ has no way to pivot from "I see this
message in DLQ" to "here is the consumer that put it here."

Why it matters: DLQ debugging is the primary operational use of
distributed tracing for queue systems. If the trace silently elides
the failing consumer, DLQ post-mortems require correlating timestamps
and message ids against logs by hand. This is the exact scenario
distributed tracing is supposed to make trivial.

Proposed fix: introduce a producer-side helper in
`shibuya-core/src/Shibuya/Telemetry/Propagation.hs` that returns the
*current* span's trace headers — call it `currentTraceHeaders ::
(Tracing :> es, IOE :> es) => Eff es (Maybe TraceHeaders)`.
Implementation: read the active span via
`OpenTelemetry.Context.ThreadLocal.lookupCurrentSpan`, wrap it via the
existing `injectTraceContext` (which already accepts a `Span`).
Returns `Nothing` when tracing is disabled or no span is active. In
`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`'s
`AckDeadLetter` branch, call `currentTraceHeaders` and merge into
`msg.headers` with the consumer's `traceparent` overriding the
producer's. The decision to *replace* rather than *augment* (vs.
adding a `linkedtraceparent` extension) should be a Decision Log
entry made when the work lands, with a citation to the relevant
section of the W3C Trace Context spec on header replacement.

Alternatives considered: (1) leave the producer's trace untouched and
add a `link` to the new `processOne` span pointing at the failing
consumer's span — works in OTel data model terms but requires the DLQ
*consumer* to know how to follow links, which most UIs do not
display by default. (2) emit a separate Producer-kind span at DLQ
write time and don't replace the header — then the DLQ message has
*two* trace contexts, which the spec disallows. The header-replace
fix is the only one that produces a clean single-message-one-trace
view at the DLQ consumer.

Prior decisions:
`docs/plans/PGMQ_OPENTELEMETRY_INSTRUMENTATION.md:308-380` describes a
`sendMessageTraced` helper in upstream `pgmq-effectful` that injects
the *current* span's trace context. That helper is the right shape
for the producer side of the framework. The shibuya adapter just
hasn't called it from the `AckDeadLetter` branch yet.


### Finding F4: `runApp` does not bracket tracing initialization; `TracingConfig` is dead code

Bucket: A (`Tracing` effect surface).
Severity: **P1**.
Evidence:
`shibuya-core/src/Shibuya/App.hs:159-167` — `runApp` requires
`(IOE :> es, Tracing :> es)` but does not initialize the
`TracerProvider` itself; the caller wraps in `runTracing tracer` or
`runTracingNoop`. `shibuya-core/src/Shibuya/Telemetry/Config.hs:14-23`
defines `TracingConfig { enabled, serviceName, serviceVersion }`, but
a grep `grep -rn "TracingConfig\|Telemetry.Config" shibuya-core/src
shibuya-core/test` returns matches only inside the module's own
file and the re-export in `Shibuya.Telemetry`. No code reads it.
`docs/plans/OPENTELEMETRY_INTEGRATION.md:300-334` proposes a
`withTracing :: TracingConfig -> (Tracer -> IO a) -> IO a` bracket
helper that does not exist in source. The same plan's Phase 2.4
(lines 884-899) proposes that `runApp` do its own initialization;
that did not land either.

What it is: an adapter integrator who follows the Quick Start in
`Shibuya.Telemetry` writes `defaultTracingConfig { enabled = True }`,
expecting it to actually do something. It does nothing: there is no
code path that reads the field. To turn tracing on, the integrator
must hand-wire `initializeGlobalTracerProvider`, `makeTracer`,
`runTracing`, and `shutdownTracerProvider` themselves — exactly what
the Kafka demo does at
`shibuya-kafka-adapter/shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs:87-90`
and what the pgmq example does likewise. Every example in the project
duplicates this 6-line incantation.

Why it matters: the gap between the Quick Start's promise and the
library's behavior is silent. A user does not get a build error if
they enable `TracingConfig.enabled = True` and never wrap with
`runTracing` — they get a Haskell type error when they forget the
wrap, but the `enabled` flag is never actually consulted. The flag
is misleading documentation. Worse, the boilerplate is brittle: a
caller who forgets `shutdownTracerProvider` loses pending spans on
exit, and the project has no central place to put the fix.

Proposed fix: introduce
`runAppTraced :: (IOE :> es) => TracingConfig -> SupervisionStrategy
-> Int -> [(ProcessorId, QueueProcessor (Tracing : es))] -> Eff es
(Either AppError (AppHandle (Tracing : es)))`
in `shibuya-core/src/Shibuya/App.hs`. When `cfg.enabled = True`, it
brackets `initializeGlobalTracerProvider` /
`shutdownTracerProvider` and feeds the resulting `Tracer` to
`runTracing`. When `cfg.enabled = False`, it dispatches to
`runTracingNoop`. Update the Quick Start in
`shibuya-core/src/Shibuya/Telemetry.hs` and the README. Migrate
`shibuya-pgmq-example` and the Kafka jitsurei demos to the new
helper. Existing `runApp` stays put — it remains the right escape
hatch for callers who want to bring their own `Tracer` (e.g., share
one across multiple `runApp` invocations).

Alternatives considered: (1) just delete `TracingConfig` and document
that the user must wrap with `runTracing`/`runTracingNoop` — works
but doubles down on the documentation/behavior gap. (2) make
`runApp` itself read a config field — breaks the simple
`runApp :: SupervisionStrategy -> ...` signature. The
`runAppTraced` helper keeps `runApp` clean and gives the config
field a real consumer.

Prior decisions:
`docs/plans/OPENTELEMETRY_INTEGRATION.md:300-334` already specified a
`withTracing` bracket; this finding revives that plan with the
narrower scope of "just bracket what `runApp` needs."


### Finding F5: `injectTraceContext` is exported but used by no in-tree adapter

Bucket: D (producer/DLQ-side propagation).
Severity: **P2**.
Evidence:
`shibuya-core/src/Shibuya/Telemetry/Propagation.hs:45-51` defines
`injectTraceContext :: Span -> IO TraceHeaders`. A grep
`grep -rn injectTraceContext shibuya-core/src
shibuya-pgmq-adapter shibuya-kafka-adapter` returns matches only in
the module that defines it, in the docs, in the kafka jitsurei
`OtelProducerDemo`, and in the integration plan documents. No
in-tree adapter calls it.

What it is: the helper is on the public surface and documented as
"Use this when producing messages that should carry trace context"
(line 36-44). Today no in-tree consumer of the public API actually
calls it from a producer-side hot path. The pgmq adapter's DLQ
write (F3) is the closest call site that *should* use it but does
not. The kafka adapter's `AckDeadLetter` branch is "deferred to
future milestone" per
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs:63`.

Why it matters: `injectTraceContext` is fine — the issue is that
nothing in-tree exercises it, so the helper drifts away from its
real-world callers' needs. Specifically, callers of
`injectTraceContext` need access to the *current* span, not an
arbitrary one; the existing signature forces them to thread the
`Span` handle from inside a `withSpan'`. F3's proposed fix
(`currentTraceHeaders`) is the higher-level helper most call sites
actually want.

Proposed fix: add `currentTraceHeaders :: (Tracing :> es, IOE :> es)
=> Eff es (Maybe TraceHeaders)` next to `injectTraceContext` in
`shibuya-core/src/Shibuya/Telemetry/Propagation.hs`. Keep
`injectTraceContext` exported (it is the lower-level primitive and
remains useful for callers that already hold a `Span` handle). The
work for F3 lands `currentTraceHeaders`; this finding is the
documentation-side counterpart that updates the haddocks to point
callers at the right primitive.

Alternatives considered: deleting `injectTraceContext` outright —
breaks the producer demo and any downstream user that might be
calling it. It is harmless to keep.

Prior decisions: plan 9 itself (the parent of this audit) calls out
this gap in its "What is *not* covered" section.


### Finding F6: `runTracingNoop` allocates a `TracerProvider` and `Tracer` per call

Bucket: A (`Tracing` effect surface).
Severity: **P2**.
Evidence:
`shibuya-core/src/Shibuya/Telemetry/Effect.hs:104-116`. Every call
constructs a fresh `TracerProvider` via
`OTel.createTracerProvider [] OTel.emptyTracerProviderOptions` and
turns it into a `Tracer` via `OTel.makeTracer`. The resulting
`TracingRep` carries `tracingEnabled = False`, and every guarded
operation (`withSpan`, `addAttribute`, …) checks that flag *before*
touching the `tracer` field, so the freshly-constructed value is
never read.

What it is: the allocation is wasted, but it is not a *runtime*
hot-path cost — `runTracingNoop` is called once per `runApp` boot,
not per message. So the practical overhead is "one TracerProvider
allocation per consumer process startup," which is invisible.

Why it matters: it is misleading to read. A reader who sees the
allocation reasonably assumes the `Tracer` matters, and may write a
second runner that depends on it. Future contributors who change
the no-op runner (e.g., to also disable propagation) will need to
re-derive what that allocation is for and why.

Proposed fix: change the `StaticRep Tracing` to make `tracer` a
`Maybe OTel.Tracer`, and have `runTracingNoop` evaluate to
`evalStaticRep (TracingRep Nothing False)`. The guarded operations
already check the `Bool` flag first; the `Maybe` is just a
truth-in-advertising change. Alternatively, leave the rep alone and
just call `OTel.makeTracer noopProvider …` once at module-init
time and reuse it (memoize). The first option is cleaner.

Alternatives considered: leave it alone — it works, and the cost is
sub-microsecond. The argument for fixing it is purely about
readability, which is why this is P2.

Prior decisions: none.


### Finding F7: `withSpan'` synthesises a misleading all-zero `FrozenSpan` when disabled

Bucket: A (`Tracing` effect surface).
Severity: **P2**.
Evidence:
`shibuya-core/src/Shibuya/Telemetry/Effect.hs:163-166` (the
`tracingEnabled = False` branch of `withSpan'`) and
`shibuya-core/src/Shibuya/Telemetry/Effect.hs:294-312` (the
`mkDummySpan` helper). When tracing is disabled, the user's callback
receives a `FrozenSpan` whose `traceId` and `spanId` are 16/8 bytes
of zero respectively.

What it is: the dummy span is *functionally* a no-op — every
`addAttribute span ...` call short-circuits inside the same `Bool`
flag — but its IDs are observable. A user who logs the span's IDs
for correlation (a common pattern) gets all zeros instead of an
"I'm disabled" signal. Worse, all-zeros is a *valid-looking* W3C
trace ID format, so a downstream system that records it has no way
to know the producer was running with tracing off.

Why it matters: this is an honesty issue, not a correctness one. It
distorts logs and breaks any correlation flow that includes both
"trace-on" and "trace-off" producers. Severity is P2 because
correlating IDs across a trace-on/trace-off boundary is uncommon.

Proposed fix: change the type of the callback in `withSpan'` from
`Span -> Eff es a` to `Maybe Span -> Eff es a`, and pass `Nothing`
in the disabled branch. This is a breaking change. Existing call
sites (`Supervised.hs::processOne`, `Tracing.hs::traced`) handle it
by either ignoring the parameter when `Nothing` (most attribute
calls already short-circuit, so a `forM_ mSpan addAttribute` works)
or — for callers that genuinely need a `Span` — by short-circuiting
the whole block with `withSpan` (no `'`). Coordinated with F4 and
the next-minor `shibuya-core` release.

Alternatives considered: leave the all-zero dummy and document the
behavior on the haddock — works but documents a footgun rather than
removing one.

Prior decisions: none.


### Finding F8: Ingester poll-loop and adapter shutdown are invisible in traces

Bucket: B (per-message span shape, broadly defined).
Severity: **P2**.
Evidence: `shibuya-core/src/Shibuya/Runner/Ingester.hs:39-60` —
`runIngesterWithMetrics` reads from the adapter's source stream and
forwards to a bounded inbox, with no `withSpan` anywhere in the body.
`shibuya-core/src/Shibuya/App.hs:241-258` — `stopAppGracefully`
invokes `shutdownAdapter (... QueueProcessor adapter _ _ _) =
adapter.shutdown` with no span coverage either. Compare to
`shibuya-core/src/Shibuya/Telemetry/Semantic.hs:69-70`, which already
defines `ingestSpanName = "shibuya.ingest"` — the helper is in place
but unused.

What it is: errors that bubble up from the source stream (a Postgres
disconnect inside `pgmqSource`, a fatal Kafka error inside
`kafkaSource`/`ingestedStream`, a malformed record at conversion
time) terminate the ingester async (visible in metrics as
`ProcessorState = Failed`) but leave no breadcrumb in the trace
store. An operator who sees a processor go to `Failed` has to dig
through logs to find the cause.

Why it matters: the symptom is rare — fatal errors in the source
stream are uncommon — but when it bites, the diagnostic value is
significant. Today, the adapter's shutdown logic has no observable
trace either, so a hung shutdown (e.g., a pgmq DB connection that
won't close) is similarly invisible.

Proposed fix: wrap the body of `runIngesterWithMetrics` in
`withSpan ingestSpanName ingestSpanArgs` (with `Internal` kind, since
it represents a process-internal coordination span). The span lives
for the lifetime of the source stream — *not* per message — so the
overhead is a single span per processor lifetime. Add `recordException`
on any caught error. Similarly wrap `Adapter.shutdown` from
`stopAppGracefully` with a per-adapter span. Optionally promote
`Ingester.runIngesterWithMetrics`'s constraint to `(IOE :> es,
Tracing :> es)` to make this cheap. Acceptance: a Jaeger trace from a
processor whose source stream throws a fatal error shows the ingest
span with a recorded `exception` event.

Alternatives considered: leave it — operators who hit this regularly
can already correlate by timestamp. P2 because the cost-benefit is
modest.

Prior decisions:
`docs/plans/OPENTELEMETRY_INTEGRATION.md:415-432` proposed a
single ingest span per processor lifetime (rather than per-message)
explicitly to keep the cost down. This finding revives that
proposal with the same scoping.


## Refuted Surprises

Plan 9's pre-implementation Surprises section
(`docs/plans/9-audit-and-improve-opentelemetry-api.md` lines 144-267)
listed S1..S7. After this audit:

-   **S1 (`runTracingNoop` allocates per call)** → confirmed as **F6**.
-   **S2 (`traced` + `processOne` open two nested Consumer spans)**
    → confirmed as **F1**, with one important refinement: the two
    spans are *siblings*, not nested, because `withExtractedContext`
    replaces the active context with one containing only the parent
    span from headers (Effect.hs:281-286). Both spans hang off the
    same parent under the same trace, which is worse than nested for
    a UI viewer trying to read the trace tree.
-   **S3 (typed Kafka attrs only on the inner span)** → confirmed as
    **F2**, with the additional observation that `messaging.system`
    differs between A and B (`"shibuya"` vs. `"kafka"`), so a
    `system=kafka` filter elides the framework span.
-   **S4 (pgmq has no symmetric `traced` module)** → **refuted as a
    distinct finding**. The asymmetry is correct: pgmq has no
    spec-defined typed attribute conventions worth a separate module,
    and once F1's fix lands, the kafka `traced` module disappears
    too, so the asymmetry is moot. The producer-side gap S4 hinted at
    is captured separately as **F3**.
-   **S5 (`runApp` does not bracket tracing init; `TracingConfig` is
    unused)** → confirmed as **F4**.
-   **S6 (`withSpan'` makes a dummy `FrozenSpan` with all-zero IDs)**
    → confirmed as **F7**.
-   **S7 (no in-tree producer-side helper)** → confirmed and split
    into **F3** (the active operational gap) and **F5** (the
    haddock/API-shape side). S7 itself, as written, is correct but
    too descriptive for a finding; F3 is the actionable subset.


## Severity calibration

Recap of plan 9 M1's severity definitions, with this audit's
populated entries:

-   **P0** — correctness or double-counting bug that distorts the
    trace shape under normal use. **F1** is the only P0.
-   **P1** — silent loss of information or strong API friction that
    drives users to write boilerplate. **F2**, **F3**, **F4**.
-   **P2** — polish. **F5**, **F6**, **F7**, **F8**.

A reader who reads only this file should be able to predict M2 and M3
of plan 9: M2 implements F1 (and absorbs F2 in the same change set,
since the fix is the same `Envelope.attributes` hook). M3 implements
F3 and F4. The P2 findings either fold into the same change set
opportunistically (F5 in particular is a haddock cross-reference
delta during F3) or are deferred to a follow-up.
