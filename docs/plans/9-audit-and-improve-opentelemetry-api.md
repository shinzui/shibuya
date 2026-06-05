---
id: 9
slug: audit-and-improve-opentelemetry-api
title: "Audit and improve Shibuya's OpenTelemetry API for adapters"
kind: exec-plan
created_at: 2026-05-05T22:19:16Z
intention: "intention_01kh0akd82ekat0be54p2f72kv"
---


# Audit and improve Shibuya's OpenTelemetry API for adapters

This ExecPlan is a living document. The sections Progress, Surprises &
Discoveries, Decision Log, and Outcomes & Retrospective must be kept up to
date as work proceeds.

This document is maintained in accordance with `.claude/skills/exec-plan/PLANS.md`.


## Purpose / Big Picture

Shibuya is a Haskell supervised queue-processing framework (see
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/CLAUDE.md`). It already
ships an OpenTelemetry (OTel) tracing surface in `shibuya-core` (modules
under `Shibuya.Telemetry.*`) and is consumed by two real adapters that live
in sibling repositories:

-   `shibuya-pgmq-adapter` at
    `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter`,
    which talks to PostgreSQL's `pgmq` queue extension.
-   `shibuya-kafka-adapter` at
    `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter`,
    which talks to Apache Kafka via `kafka-effectful` /
    `hw-kafka-client`.

The point of this work is to step back and ask, after the dust has settled
on the two recent attribute-conventions alignment plans
(`docs/plans/2-align-opentelemetry-semantic-conventions.md` here, and
`shibuya-kafka-adapter/docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md`
in the sibling repo), three questions:

1.  **Is the public OpenTelemetry API in `shibuya-core` good?** That is:
    is it clear, minimal, hard to misuse, and predictable in cost when
    enabled or disabled?
2.  **Is it easy for an adapter author to integrate OpenTelemetry**,
    specifically in the two ways an adapter ever touches tracing — the
    consume side (extracting parent context from queue-native headers,
    enriching the framework's per-message span with broker-specific
    attributes) and the produce side (injecting the current trace
    context into queue-native headers when the adapter sends to a
    DLQ/retry queue)?
3.  **What concrete improvements should land** to remove the worst
    rough edges that the audit surfaces, in priority order?

The audit is not a code-change plan in itself. Milestone 1 produces an
audit document — checked into `docs/plans/9-audit-and-improve-opentelemetry-api.md`'s
own Outcomes & Retrospective and Surprises sections, plus a short
companion file `docs/plans/9-otel-audit-findings.md` that we will
generate during M1 — that names every wart, with file:line evidence,
and ranks them. Milestones 2..N then implement the highest-priority
fixes one by one.

After this work, a reader of the plan and the codebase will be able to:

-   Read `docs/plans/9-otel-audit-findings.md` and see, for each
    identified API problem and each adapter integration friction, a
    file:line citation and a one-paragraph fix proposal.
-   Run `cabal build all` in `shibuya-core`, in
    `shibuya-pgmq-adapter`, and in `shibuya-kafka-adapter` and observe
    no regression.
-   Run `cabal test shibuya-core-test`, `cabal test
    shibuya-pgmq-adapter-test` (the integration-tagged subset that
    does not require a real PostgreSQL), and `cabal test
    shibuya-kafka-adapter-test:unit` (the broker-free portion) and
    see all green, including any new tests added by the
    improvement milestones.
-   For each improvement landed, see a Jaeger trace (or an in-memory
    span exporter test) demonstrating the change in observable
    behaviour: span name, kind, attribute set, parenting.

Concretely this means that, by the end of any improvement milestone
that touches the consumer hot path, an adapter author can integrate
OpenTelemetry tracing for a new adapter in **one** place — by
populating `Envelope.traceContext` from queue-native headers in
`Convert.hs` — and not need a second adapter-side `traced` wrapper at
all, unless they want to add broker-specific attributes that the
framework does not know about. Today, by contrast, the Kafka adapter
ships a 100-line `Shibuya.Adapter.Kafka.Tracing` module specifically
to bolt Kafka-typed attributes onto the consumer span, the pgmq
adapter does not have an equivalent at all, and an unwary caller who
combines `traced` with `runApp` ends up with two nested
Consumer-kind "process" spans per message (see Surprise S2 below).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be
documented here, even if it requires splitting a partially completed task
into two ("done" vs. "remaining"). This section must always reflect the
actual current state of the work.

-   [x] M1.1 — Audit `shibuya-core/src/Shibuya/Telemetry/*` against
    the goals stated in `docs/plans/OPENTELEMETRY_INTEGRATION.md`. Read
    every public export, classify it as load-bearing or vestigial,
    and record findings in the new file
    `docs/plans/9-otel-audit-findings.md`. Done 2026-05-05.
-   [x] M1.2 — Audit the consumer-side telemetry path in
    `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` and
    `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`.
    Specifically: how `traceparent`/`tracestate` round-trips into
    `Envelope.traceContext`; how the DLQ path
    (`mkAckHandle`, `AckDeadLetter` branch) preserves or fails to
    preserve trace context; whether per-poll errors are traceable.
    Done 2026-05-05; landed as Finding F3 (DLQ writes forward the
    original producer's `traceparent` and never inject the failing
    consumer's).
-   [x] M1.3 — Audit the consumer-side telemetry path in
    `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs`,
    `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`,
    and the opt-in `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs`.
    Specifically: whether the `traced` stream transformer and the
    framework-owned `processOne` span overlap (Surprise S2 below),
    whether broker-specific typed attributes
    (`messaging.kafka.destination.partition`,
    `messaging.kafka.message.offset`) belong on the framework span
    instead of on a separate adapter-owned span, and whether the
    asymmetry with pgmq (no equivalent module exists there) is
    deliberate. Done 2026-05-05; landed as Findings F1 and F2 (with
    a refinement: the two spans are siblings under the same parent,
    not nested, because `withExtractedContext` replaces the active
    context).
-   [x] M1.4 — Cross-reference the audit findings against the
    superseded plans
    (`docs/plans/OPENTELEMETRY_INTEGRATION.md`,
    `docs/plans/PGMQ_OPENTELEMETRY_INSTRUMENTATION.md`,
    `shibuya-kafka-adapter/docs/plans/8-investigate-hw-kafka-client-instrumentation.md`,
    `shibuya-kafka-adapter/docs/plans/9-add-shibuya-kafka-tracing-module.md`)
    so that no finding "rediscovers" a deliberate prior decision
    without saying so. Done 2026-05-05; every Finding cites the
    relevant prior plan in its "Prior decisions" line.
-   [x] M1.5 — Write `docs/plans/9-otel-audit-findings.md` with a
    triaged findings table, each finding tagged P0/P1/P2 with a
    one-paragraph proposed fix, and commit it. Done 2026-05-05.
-   [/] M2 — Implement the P0 fix(es) named by the audit, with tests
    and a Jaeger demo. Each P0 lands as its own commit with the
    `ExecPlan:` and `Intention:` trailers. Update Surprises and
    Decision Log when implementation reveals a fact the audit missed.
    -   [x] M2.1 — `shibuya-core` 0.5.0.0: add
        `Envelope.attributes :: HashMap Text Attribute`, have
        `processOne` merge envelope-supplied attrs over framework
        defaults (left-biased union — adapter wins), update tests,
        bump versions, update CHANGELOGs. Done 2026-05-05; the new
        `SemanticSpec` case "applies envelope.attributes onto the
        framework span (P0 fix, plan 9 F1/F2)" passes; the original
        case "emits a process span with conventions-aligned
        attributes and events" still passes.
    -   [x] M2.2 — `shibuya-pgmq-adapter`: bumped to
        `shibuya-core ^>=0.5`, populate `Envelope.attributes`
        (empty HashMap for pgmq today; future hook), tests +
        version bumped. Landed in shibuya-pgmq-adapter commit
        `274c0eb`. Decision Log entry on 2026-05-05 relaxed the
        "no path-based pins" rule to allow gitignored
        `cabal.project.local` for development.
    -   [x] M2.3 — `shibuya-kafka-adapter`: bumped to
        `shibuya-core ^>=0.5`, populate `Envelope.attributes` from
        the Kafka `ConsumerRecord` (system + typed
        `messaging.kafka.*`), `Shibuya.Adapter.Kafka.Tracing`
        deleted, OtelDemo migrated to `runWithMetrics`, version
        bumped. Landed in shibuya-kafka-adapter commit `0440544`.
-   [x] M3.1 — F3 (P1) DLQ trace propagation: added
    `currentTraceHeaders` in shibuya-core (commit `193de1d`) and
    consumed it in pgmq's `mkAckHandle (AckDeadLetter _)` branch
    (shibuya-pgmq-adapter commit `274c0eb`). Five new
    `mergeDlqHeaders` spec cases pass.
-   [ ] M3.2..M3.4 — F4 (`runAppTraced` bracket), F6
    (`runTracingNoop` allocation), F7 (`withSpan'` dummy span), F8
    (ingester poll-loop visibility) deferred to a follow-up plan.
    See "Gaps" in Outcomes for rationale.
-   [x] M4 — Refresh `docs/plans/OPENTELEMETRY_INTEGRATION.md` to
    reflect the audited and updated state of the API (added a
    "Current State (2026-05-05)" section and inline `[SUPERSEDED]`
    banners; populated the Phase 1/2/3 deliverable checklists with
    shipped vs. open status). Ran `nix fmt`, `nix flake check`,
    and the unit-tagged `cabal test` matrix in all three repos —
    all green (see "Acceptance gates" in Outcomes). Outcomes &
    Retrospective filled. Done 2026-05-05.


## Surprises & Discoveries

Document unexpected behaviours, bugs, optimizations, or insights discovered
during implementation. Provide concise evidence.

The list below is the **pre-implementation** set of suspicions that
prompted this plan. They are recorded here so M1 has a target to
verify or refute. Each entry calls out a file path the audit must
revisit; if the suspicion does not survive close inspection, M1 must
say so explicitly and update the entry.

### S1 — `runTracingNoop` allocates a real `TracerProvider` on every call

Evidence: `shibuya-core/src/Shibuya/Telemetry/Effect.hs:104-116`. The
"noop" runner creates a fresh `TracerProvider` with no processors and
makes a `Tracer` from it on every call. Every guarded operation
(`withSpan`, `addAttribute`, etc.) then has the same `tracingEnabled`
flag check anyway. This is harmless for a single `runApp` boot but
suggests the `Bool` flag is the real shutoff and the `Tracer`
allocation is wasted work.

### S2 — `Shibuya.Adapter.Kafka.Tracing.traced` and `processOne` open *two* nested Consumer spans per message when used together

Evidence:
`shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs:90-101`
wraps the `Ingested.ack.finalize` with a `withSpan' (processSpanName
topicName) consumerSpanArgs $ \\sp -> ... finalize decision`.
`shibuya-core/src/Shibuya/Runner/Supervised.hs:374-452` (the
`processOne` body) already opens `withSpan' (processSpanName pidText)
consumerSpanArgs $ \\traceSpan -> ... ingested.ack.finalize decision
...`. Inside `runApp`, both fire: the outer span from `processOne`
brackets the handler call AND the call to `finalize`, and the inner
span from `traced` brackets just the call to `finalize`. Both use
`SpanKind=Consumer`. Both follow the `<destination> <operation>`
naming pattern. This is double-counting.

The Kafka adapter's
`shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs` does **not** use
`runApp`; it drives the stream by hand and calls `finalize AckOk`
inline, so the demo only sees a single span, which is why the
double-span condition has not been observed in the existing Jaeger
verification. M1.3 must verify this with a runApp-style test.

### S3 — Adapter-specific typed attributes are scattered across the wrong span

Evidence: the per-message processing span is opened in
`Shibuya/Runner/Supervised.hs:374`, and is the canonical
"this-is-a-process-operation" span for the framework. However
`messaging.kafka.destination.partition` and
`messaging.kafka.message.offset` are only set by
`Shibuya/Adapter/Kafka/Tracing.hs`'s `populateAttrs` on the **inner**
span. So a user who turns on tracing without importing the adapter's
`traced` (which is the path described in
`docs/plans/OPENTELEMETRY_INTEGRATION.md`'s Quick Start) sees the
processOne span without those Kafka attributes. Conversely, a user
who imports `traced` sees them only on the inner span, not on the
processOne span.

The clean separation would be: the framework owns the span, the
adapter contributes attributes to it. There is no API for the
adapter to do that today — `Envelope` carries `traceContext` only,
not adapter-specific span attributes.

### S4 — The pgmq adapter has no symmetric `traced` module

Evidence: `find shibuya-pgmq-adapter -name "Tracing.hs"` returns
nothing; `grep -n 'Tracing\|withSpan' shibuya-pgmq-adapter/...src/.../*.hs`
returns nothing. The pgmq adapter relies on
(i) `Convert.extractTraceHeaders` to populate
`Envelope.traceContext` and (ii) the framework's `processOne` span
to carry messaging.* attributes, which it does correctly. So pgmq
emits a single Consumer span per message, with no Kafka-specific
typed attributes — there is no `messaging.pgmq.*` set, and there are
no spec-defined PGMQ keys upstream.

This asymmetry is **probably correct** (PGMQ just doesn't have
broker-specific attribute conventions the way Kafka does), but
`docs/plans/PGMQ_OPENTELEMETRY_INSTRUMENTATION.md` does mention DLQ
trace preservation and producer-side `sendMessageTraced`. M1.2 must
check whether DLQ writes from the consumer hot path retain the
**consumer's** trace context (so the next consumer of the DLQ sees a
linked trace), or whether they only forward the **original
producer's** headers (in which case the consumer's DLQ-write step is
invisible).

### S5 — `runApp` does not bracket tracing initialization

Evidence: `shibuya-core/src/Shibuya/App.hs:159-167`. `runApp`
requires `(IOE :> es, Tracing :> es)` but does not initialize a
`TracerProvider` itself; the caller must wrap with
`runTracing tracer` or `runTracingNoop`. This is a fine library
choice (no opinion on exporters) but means every example wires
tracing by hand. The `TracingConfig` type defined in
`Shibuya/Telemetry/Config.hs:16-23` is unused: `runApp` never reads
it. The plan
`docs/plans/OPENTELEMETRY_INTEGRATION.md:300-334` proposed a
`withTracing :: TracingConfig -> (Tracer -> IO a) -> IO a` bracket;
that helper does not exist in the source tree.

### S6 — `withSpan'` synthesises a "dummy" span when tracing is disabled

Evidence:
`shibuya-core/src/Shibuya/Telemetry/Effect.hs:163-166` and
`shibuya-core/src/Shibuya/Telemetry/Effect.hs:294-312`. When
`tracingEnabled = False`, `withSpan'` constructs a `FrozenSpan` with
all-zero `traceId`/`spanId` and hands it to the user callback. The
user's `addAttribute span k v` calls then check the same `Bool` flag
and short-circuit, so this is functionally fine, but the user is
holding a span handle whose IDs are misleading if they ever inspect
it (e.g., for logging). A truer `Maybe Span` would force the user to
handle the disabled case explicitly.

### S7 — There is no in-tree producer-side helper, by design

Evidence: `grep -rn injectTraceContext shibuya-core/src` shows the
function defined at
`shibuya-core/src/Shibuya/Telemetry/Propagation.hs:45` but used only
in the kafka-adapter-jitsurei OtelProducerDemo
(`shibuya-kafka-adapter/shibuya-kafka-adapter-jitsurei/app/OtelProducerDemo.hs`).
On the pgmq side, the producer helper `sendMessageTraced` lives in
the upstream `pgmq-effectful` package, not in `shibuya-pgmq-adapter`.
This is consistent with each adapter's role (consume-only) but
means there is no documented framework recommendation about how a
DLQ write from the consumer path should be traced.

### M1 — audit completed, findings filed (2026-05-05)

Audit deliverable lives at
`docs/plans/9-otel-audit-findings.md`. Eight Findings filed:

-   **F1 (P0):** `traced` + `runApp` emits two duplicate Consumer
    spans per message — confirms S2, with a refinement: the two
    spans are *siblings* under the same parent, not nested, because
    `Shibuya.Telemetry.Effect.withExtractedContext` calls
    `Ctx.attachContext (Ctx.insertSpan parentSpan Ctx.empty)` which
    *replaces* the active thread-local context with one containing
    only the parent span from headers
    (`shibuya-core/src/Shibuya/Telemetry/Effect.hs:281-286`). The
    inner `withSpan'` therefore parents to the headers' parent, not
    to the framework's outer span.
-   **F2 (P1):** Kafka-typed attributes only on the adapter span,
    not the framework's. `messaging.system` differs between the two
    spans (`"shibuya"` on `processOne`, `"kafka"` on `traced`'s
    span), so a `messaging.system=kafka` filter elides the framework
    span entirely.
-   **F3 (P1):** pgmq DLQ writes forward the original producer's
    `traceparent` verbatim and never inject the failing consumer's
    trace context
    (`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:201-252`).
    This is the most operationally damaging gap.
-   **F4 (P1):** `runApp` does not bracket tracing init;
    `TracingConfig.enabled` is dead code (no module reads it).
-   **F5 (P2):** `injectTraceContext` is exported but called by no
    in-tree adapter, only the kafka jitsurei demo. The right fix is
    to add a `currentTraceHeaders` helper alongside it (deferred to
    F3's implementation).
-   **F6 (P2):** `runTracingNoop` allocates a `TracerProvider` per
    call (S1 confirmed).
-   **F7 (P2):** `withSpan'` synthesises an all-zero `FrozenSpan`
    when disabled (S6 confirmed).
-   **F8 (P2):** Ingester poll-loop and adapter shutdown are
    invisible in traces.

S4 (pgmq has no symmetric `traced` module) is **refuted as a
distinct finding**: the asymmetry is correct, and once F1 lands the
kafka `traced` module disappears too.

### M2.1 — `Attribute` lacks an upstream `NFData` instance (2026-05-05)

While implementing F1's fix in `shibuya-core`, `Envelope`'s
`deriving anyclass (NFData)` clause stopped working as soon as the
new `attributes :: HashMap Text Attribute` field was added.
`hs-opentelemetry-api`'s `OpenTelemetry.Attributes.Attribute`
derives `(Read, Show, Eq, Ord, Data, Generic, TH.Lift)` and a
`Hashable` anyclass — but no `NFData`. The bench harness at
`shibuya-core-bench/bench/Bench/Framework.hs:104` (the
`map (.envelope) msgs \`deepseq\` …` line) requires
`NFData (Envelope BenchMessage)`, so dropping the derivation was
not an option. Rather than ship an orphan `NFData Attribute`
instance from inside `shibuya-core`, the chosen fix is a manual
`instance NFData (Envelope msg)` body that deeply-forces every
existing field and reduces `attributes` to WHNF — every
`Attribute` leaf is `Text`/`Bool`/`Double`/`Int64`, all of which
are NF-equivalent at WHNF when the enclosing `HashMap` is itself
in WHNF, so the bench-harness's deepseq behavior is unchanged for
the practical shape of the attribute values that adapters
populate. Recorded so a future contributor who edits
`Shibuya.Core.Types` knows why the instance is hand-written.

### M2.1 — `addAttribute` ordering against the adapter's HashMap is non-obvious (2026-05-05)

The first attempt at F1's fix in `processOne` left the existing
`addAttribute traceSpan attrMessagingSystem ("shibuya" :: Text)`
calls in place and then called
`addAttributes traceSpan ingested.envelope.attributes` afterwards.
`OpenTelemetry.Attributes.addAttributes` (upstream) implements its
merge as `HashMap.union (mapped attrs) attributeMap` — left-biased
in the new batch — so the adapter's `messaging.system="kafka"`
*should* win over the framework's prior `"shibuya"` write. In
practice the new test
`SemanticSpec.applies envelope.attributes onto the framework span`
still saw `"shibuya"` on the span. The exact reason was not
chased to ground; the surface-level fix is to assemble the
framework-default attribute set into a single
`HashMap Text Attribute` and union the adapter's HashMap over it
with `HashMap.union envelope.attributes frameworkDefaults`
(left-biased, adapter wins), then call `addAttributes` once.
This makes the precedence rule explicit at the call site rather
than relying on the upstream's per-call merge order against the
mutable Span's IORef. The new test now passes; the original
SemanticSpec case ("emits a process span with conventions-aligned
attributes and events") still passes too. Shibuya-specific
attributes (`shibuya.inflight.count`, `shibuya.ack.decision`) are
still set via individual `addAttribute` calls because they are
not duplicated against any adapter-supplied keys.


## Decision Log

Record every decision made while working on the plan.

-   Decision: Run the audit as Milestone 1 with a written deliverable
    (`docs/plans/9-otel-audit-findings.md`) before any code changes,
    even though that file does not exist yet.
    Rationale: every prior plan in the docs/plans/ tree that touches
    OpenTelemetry (plan 2 on attribute conventions, the Kafka
    adapter's plans 8/9/10) has converged on a tighter scope after a
    careful read-back of code and prior decisions. Without an audit
    deliverable in this plan, M2+M3 risk re-litigating the same
    Kafka-vs-Shibuya namespace question that plans 9 and 10 in the
    Kafka repo already answered.
    Date: 2026-05-05.

-   Decision: Treat the cross-repo state as one audit target rather
    than splitting per repository.
    Rationale: the API is in `shibuya-core` and the consumers are in
    sibling repos. The friction is in the seam, so the audit must
    look at both ends of the seam at once. The improvement
    milestones may still split per-repo (and need to commit
    per-repo, since the adapters are separate cabal packages), but
    the analysis stays unified.
    Date: 2026-05-05.

-   Decision: The audit considers four separable concerns and treats
    them independently when producing recommendations: (a) the
    `Tracing` effect surface itself, (b) the per-message span shape
    contract between the framework and adapters, (c) the parent
    context propagation contract via `Envelope.traceContext`, and
    (d) the producer/DLQ-side propagation contract.
    Rationale: today these are entangled. Plan 2 fixed (b) at the
    attribute level; plan 9 (Kafka-side) fixed (c) for Kafka and
    accidentally created the double-span problem at (b); pgmq has
    (c) on consume but nothing for (d). Audit findings need to be
    pinned to one of these four buckets so the priority decision is
    not "fix everything".
    Date: 2026-05-05.

-   Decision: M2 will implement F1 (P0). The fix is the
    `Envelope.attributes` hook described in F1's Proposed fix line.
    F2 (P1) lands in the same change set because the fix is the same
    code path. F3 (P1) and F4 (P1) are M3. The remaining P2 findings
    (F5, F6, F7, F8) are folded into M3 opportunistically or
    deferred to a follow-up.
    Rationale: F1's fix removes `Shibuya.Adapter.Kafka.Tracing` (or
    shrinks it to a one-line `populateAttributes :: Envelope v ->
    Envelope v` helper), which is the single largest API
    simplification the audit found. F3 is the highest-impact P1 from
    an operational standpoint (DLQ post-mortems are the core use
    case for distributed tracing in queue systems). F4 is the
    highest-impact P1 for new-adapter authors.
    Date: 2026-05-05.

-   Decision: `Envelope.attributes` is `HashMap Text Attribute`
    (mempty default), not `Maybe (HashMap Text Attribute)`.
    Rationale: empty hashmap is the natural "nothing to contribute"
    signal and avoids the `forM_ envAttrs (addAttributes traceSpan)`
    unwrap in `processOne`. Construction sites pay one extra line
    (`attributes = HashMap.empty`) which is consistent with the
    rest of the codebase's `Envelope` literals in tests and the
    bench harness.
    Date: 2026-05-05.

-   Decision: M2 splits per repo per the plan's idempotence section.
    `shibuya-core` 0.5.0.0 lands first (this commit). The two
    adapter repos' edits (M2.2, M2.3) wait until 0.5.0.0 publishes
    to Hackage, because the plan forbids path-based pins for
    cross-repo integration testing.
    Rationale: respects the plan's published-package-as-source-of-
    truth invariant. Cost: M2.2 / M2.3 cannot be locally verified
    against 0.5.0.0 until publication. Acceptable trade-off because
    the shibuya-core test added in M2.1 (the new SemanticSpec case)
    already exercises the `Envelope.attributes` → `processOne` →
    in-memory exporter round trip end-to-end, which is the
    behavioral proof that F1's fix works.
    Date: 2026-05-05.

-   Decision: in `processOne`, framework-default `messaging.*`
    attributes are now built up into a single `HashMap` and
    union'd with `Envelope.attributes` (adapter's HashMap left,
    framework defaults right — left-biased so adapter wins), then
    flushed via one `addAttributes` call. `shibuya.*` attributes
    (`inflight.count`, `inflight.max`, `ack.decision`) are still
    set via individual `addAttribute` calls because they have no
    duplication against adapter-supplied keys.
    Rationale: the upstream `Span`-level `addAttributes` does
    implement a left-biased merge per
    `OpenTelemetry.Attributes.addAttributes`, but the precedence
    rule is easier to read when made explicit at the call site
    rather than spread across multiple per-attribute calls against
    the mutable Span. The first attempt (sequential
    `addAttribute … "shibuya"` then `addAttributes envAttrs`)
    surfaced as the test failure documented in Surprises.
    Date: 2026-05-05.


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at
completion. Compare the result against the original purpose.

### Outcomes (2026-05-05)

The plan set out to (a) audit Shibuya's OpenTelemetry API surface,
(b) name the worst frictions for adapter authors, and (c) implement
the highest-priority fixes. After the work landed:

-   **Audit deliverable** — `docs/plans/9-otel-audit-findings.md`
    enumerates eight findings with file:line evidence and severity
    triage. Pre-implementation Surprises S1..S7 are mapped onto
    Findings F1..F8 (S4 refuted as a distinct finding; absorbed by
    F1's fix). The status column on the triage table tracks what
    landed.
-   **F1 (P0) — duplicate Consumer span** — fixed by adding
    `Envelope.attributes :: HashMap Text Attribute` to
    `Shibuya.Core.Types` (shibuya-core 0.5.0.0, commit `7c6586b`).
    `processOne` now merges adapter-supplied attributes over its
    framework defaults (left-biased union) and flushes via a single
    `addAttributes` call. The Kafka adapter populates the typed
    `messaging.kafka.*` attributes plus
    `messaging.system="kafka"`; `Shibuya.Adapter.Kafka.Tracing` and
    its test are deleted (kafka-adapter 0.5.0.0, commit `0440544`).
    The pgmq adapter populates `HashMap.empty` (no spec-defined
    typed conventions today; pgmq-adapter 0.5.0.0, commit `274c0eb`).
-   **F2 (P1)** — subsumed by F1's fix (typed Kafka attributes now
    land on the framework span).
-   **F3 (P1) — DLQ writes carry the original producer's
    traceparent** — fixed by adding
    `Shibuya.Telemetry.Propagation.currentTraceHeaders` to
    shibuya-core (commit `193de1d`) and consuming it in pgmq's
    `mkAckHandle (AckDeadLetter _)` branch. The consumer's
    traceparent now becomes the active value on the DLQ message;
    the producer's is preserved under
    `x-shibuya-upstream-traceparent`. Five new
    `Shibuya.Adapter.Pgmq.InternalSpec` cases assert the merge
    contract directly. Kafka has no DLQ today (deferred).
-   **F4 / F6 / F7 / F8 (P1/P2)** — open. The audit's "what's
    next" recommendation: F4 (`runAppTraced` bracket) is the
    highest-impact remaining fix for new-adapter authors; F8
    (ingester-loop visibility) is the next highest-impact.
-   **F5 (P2)** — resolved as documentation: `injectTraceContext`
    stays exported as the lower-level primitive;
    `currentTraceHeaders` is the recommended higher-level entry.
-   **Cross-repo discipline** — the plan's original rule "do not
    introduce path-based pins to test the integration before
    publishing" was relaxed mid-work to "do not commit path-based
    pins; gitignored `cabal.project.local` is fine for development."
    The pgmq adapter already followed that pattern; the kafka
    adapter adopted it for this work.
    `cabal.project.local` is gitignored in both adapters; committed
    `cabal.project` continues to point at Hackage.

### Acceptance gates (2026-05-05)

Run from the project root of each repo:

| Gate | shibuya | shibuya-pgmq-adapter | shibuya-kafka-adapter |
|------|---------|----------------------|-----------------------|
| `cabal build all` | ✅ | ✅ | ✅ |
| `cabal test` (full suite) | ✅ 116/116 | ✅ 125/125 (incl. DB integration + chaos, against existing local Postgres) | ✅ 26/26 (incl. Redpanda integration) |
| `nix flake check` | ✅ | ✅ | ✅ |
| Live Jaeger smoke | ✅ (covered transitively via the two adapter demos) | ✅ (`shibuya-pgmq-simulator` + `shibuya-pgmq-consumer`) | ✅ (`otel-producer-demo` + `otel-demo`) |
| Hackage publication | _pending_ | _pending_ | _pending_ |

All in-tree verification is green. Hackage publication is the
remaining operator action.

Live Jaeger smoke transcript (run 2026-05-05; `~/.local/bin/jaeger`
+ Redpanda via `just process-up`):

-   **Kafka producer→consumer round trip.** `otel-producer-demo`
    emitted two records (`upstream-key`, `diy-key`) with
    `traceparent` headers. `otel-demo` consumed both. Inspecting
    the Jaeger trace `8754d1c69c6577bbe7a6595293c77dde` (the
    DIY-branch trace) showed exactly two spans: a producer span
    `shibuya.send.message` (kind=producer) and a single consumer
    span `orders process` (kind=consumer) parented as `CHILD_OF`
    the producer's `5e9480617881e53d` span. The `orders process`
    span carried both the spec-aligned messaging.* attributes
    AND the typed `messaging.kafka.destination.partition=0`,
    `messaging.kafka.message.offset=3`, `messaging.system=kafka`
    contributed by the adapter via `Envelope.attributes` —
    confirming F1 (no duplicate sibling Consumer span) and F2
    (typed Kafka attrs land on the framework span, not on a
    separate one).
-   **pgmq end-to-end.** `shibuya-pgmq-simulator` enqueued 5
    orders messages with W3C traceparent headers via
    `sendMessageTraced`. `shibuya-pgmq-consumer` processed all
    five. A representative trace's spans:
    `pgmq.produce` (producer) → `publish orders` (producer,
    pgmq-effectful) → `orders process` (consumer, framework
    processOne, single span) → `pgmq.delete orders` (internal,
    ack/delete). The `orders process` span was correctly
    `CHILD_OF` the producer side, confirming
    `Envelope.traceContext` round-trip via
    `Convert.extractTraceHeaders` works under `runApp`.

### Findings landed by commit

| Repo | Commit | Findings |
|------|--------|----------|
| shibuya | `8234f1a` | M1 — audit deliverable filed |
| shibuya | `7c6586b` | M2.1 — F1 (P0), F2 (P1) |
| shibuya | `193de1d` | M3.1 — F5 (P2) infrastructure for F3 |
| shibuya | `d5024b1` | M4 — refresh `OPENTELEMETRY_INTEGRATION.md` |
| shibuya-kafka-adapter | `0440544` | F1 (P0) adapter half — typed attrs in `Convert.hs`; `Tracing` module deleted |
| shibuya-pgmq-adapter | `274c0eb` | F3 (P1) — DLQ trace propagation in `mkAckHandle` |

### Gaps (open work)

-   **F4 (P1) — `runApp` does not bracket tracing init.**
    Recommended follow-up: add a `runAppTraced :: TracingConfig ->
    SupervisionStrategy -> Int -> [(ProcessorId, QueueProcessor
    (Tracing : es))] -> Eff es (Either AppError (AppHandle (Tracing
    : es)))` bracket helper in `Shibuya.App` that owns
    `initializeGlobalTracerProvider` /
    `shutdownTracerProvider` and dispatches to `runTracing`
    (when `cfg.enabled`) or `runTracingNoop`. Shibuya-core local;
    no cross-repo coordination.
-   **F6 (P2)** — `runTracingNoop` allocates a `TracerProvider`
    per call. Cosmetic; works correctly today.
-   **F7 (P2)** — `withSpan'`'s all-zero dummy `FrozenSpan`.
    Cosmetic. Fix is a breaking type change
    (`Span -> Eff es a` → `Maybe Span -> Eff es a`).
-   **F8 (P2)** — Ingester poll-loop and adapter-shutdown spans.
    Useful when source-stream errors are the symptom but rare
    enough that priority is low.
-   **Kafka DLQ propagation** — kafka-adapter does not implement
    DLQ today; the analogous F3 work for kafka is its own future
    plan when DLQ lands.
-   **Postgres-backed integration test for F3** — the runtime
    "consumer-traceparent wins under `runTracing`" assertion in
    `ChaosSpec` is deferred. The unit-level `mergeDlqHeaders` spec
    covers the merge contract directly.
-   **Live Jaeger smoke (cleared 2026-05-05)** — both adapters'
    demos were exercised end-to-end against a live Jaeger v2 +
    Redpanda + Postgres stack. Trace shapes match the audit's
    "Proposed fix" predictions for F1 and F2. Recipes remain
    documented in each adapter's README and in plan 1 / plan 12
    Concrete Steps for future verification.

### Lessons

-   The original strict reading of "no path-based pins" was
    operationally too conservative. The pgmq adapter's existing
    `cabal.project.local` pattern (committed comment naming the
    unreleased version) is the established practice and works well.
    The Decision Log entries in the per-repo plans capture the
    revised interpretation.
-   `hs-opentelemetry-api`'s `Attribute` lacking `NFData` is the
    kind of upstream gap that surfaces only when downstream code
    derives `NFData` via `Generic`. The fix (manual instance) is
    cheap; the discovery is worth recording so future contributors
    do not delete the manual instance assuming derivation works.
-   The upstream `addAttributes`'s left-biased union is correct in
    isolation but produced surprising results when interleaved
    with prior `addAttribute` calls on the same Span. Building
    the framework defaults into a HashMap and unioning the
    adapter's HashMap over them at the call site makes the
    precedence rule easier to read and reason about. Plan 9 M2.1
    Surprise records the attempt-and-correction cycle.


## Context and Orientation

A reader who has never seen this codebase needs four facts to follow
the rest of this plan.

### Repository layout

The "shibuya project" is a multi-repo whose top-level layout sits
under
`/Users/shinzui/Keikaku/bokuno/shibuya-project/`. The directories
that matter here are:

    shibuya/                       This repo. Holds shibuya-core
                                   (the library), shibuya-example,
                                   shibuya-pgmq-example (consumer +
                                   simulator using pgmq), and the
                                   docs/plans/ tree where this plan
                                   lives.

    shibuya-pgmq-adapter/          A sibling repo holding the cabal
                                   package shibuya-pgmq-adapter
                                   (PostgreSQL pgmq adapter) plus
                                   its bench package and tests.

    shibuya-kafka-adapter/         A sibling repo holding the cabal
                                   package shibuya-kafka-adapter
                                   (Apache Kafka adapter), its
                                   bench, its `jitsurei` (literally
                                   "real-world example") executable
                                   crate where the OtelDemo and
                                   OtelProducerDemo live, and tests.

The current working directory for every command in this plan is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` unless
explicitly stated otherwise. The two adapters are out-of-tree but
on-disk, and `cabal` resolves them via `shibuya-core` on Hackage
(`shibuya-core 0.4.0.0`), not via path-local pins.

### shibuya-core's telemetry surface

The library `shibuya-core` (cabal file at
`shibuya-core/shibuya-core.cabal`, version 0.4.0.0) exposes a
single tracing entry-point module
`Shibuya.Telemetry`
(`shibuya-core/src/Shibuya/Telemetry.hs`) that re-exports four
sub-modules:

-   `Shibuya.Telemetry.Config` — defines
    `data TracingConfig = TracingConfig { enabled :: !Bool, serviceName ::
    !Text, serviceVersion :: !(Maybe Text) }` and a
    `defaultTracingConfig :: TracingConfig` whose `enabled` is
    `False`. Used by **no** other module in shibuya-core. It is
    documentation-only today.
-   `Shibuya.Telemetry.Effect` — defines the `Tracing` static
    effect, runners `runTracing :: Tracer -> Eff (Tracing : es) a ->
    Eff es a` and `runTracingNoop :: Eff (Tracing : es) a -> Eff es
    a`, span operations `withSpan` /
    `withSpan'`, mutators `addAttribute` /
    `addAttributes` / `addEvent` / `recordException` /
    `setStatus`, and the helper
    `withExtractedContext :: Maybe SpanContext -> Eff es a -> Eff
    es a` that runs an action under an extracted parent context.
    Re-exports a curated subset of the upstream `OpenTelemetry.Trace.Core`
    types (`Span`, `SpanArguments`, `SpanKind`, `SpanStatus`,
    `NewEvent`, `Tracer`, `defaultSpanArguments`, `toAttribute`)
    so adapters do not have to depend on
    `hs-opentelemetry-api` directly to build a `SpanArguments`.
-   `Shibuya.Telemetry.Propagation` — defines
    `extractTraceContext :: TraceHeaders -> Maybe SpanContext` (W3C
    `traceparent`/`tracestate` headers → SDK `SpanContext`) and
    `injectTraceContext :: Span -> IO TraceHeaders` (live span →
    headers). Both delegate to
    `OpenTelemetry.Propagator.W3CTraceContext`'s `decodeSpanContext`
    / `encodeSpanContext`.
-   `Shibuya.Telemetry.Semantic` — defines the spec-aligned
    attribute-key constants (derived via `unkey` from typed
    `AttributeKey` values in
    `OpenTelemetry.SemanticConventions`), span-name helpers
    (`processSpanName`, `ingestSpanName`), and `SpanArguments`
    helpers (`consumerSpanArgs`, `internalSpanArgs`). This was the
    target of the recent
    `docs/plans/2-align-opentelemetry-semantic-conventions.md`.

A reader who has not seen the framework should understand four
non-obvious terms used heavily below:

-   **Effect** — in this codebase, an effectful effect (lower-case)
    in the sense of the `effectful` library: a marker phantom type
    `Tracing :: Effect`, with a single instance dispatch and a
    record of static state (the `Tracer` and the `Bool` enabled
    flag). Operations on the effect take `(Tracing :> es, IOE :>
    es) =>` constraints.
-   **Span** — a single timed, named operation in a distributed
    trace. The framework opens one per message in
    `processOne`. Adapters may open additional spans inside the
    handler if they wish, but should not duplicate the per-message
    span.
-   **SpanContext** — the ID triple (traceId, spanId, traceFlags,
    traceState) of a span, sufficient to wire it as a parent to
    another span. This is what gets serialised into the
    `traceparent` header.
-   **`Envelope.traceContext`** — a field of type `Maybe TraceHeaders`
    on `Envelope` (defined at
    `shibuya-core/src/Shibuya/Core/Types.hs:50-66`). `TraceHeaders`
    is `[(ByteString, ByteString)]`. The adapter populates this
    from the queue-native headers; the framework's `processOne`
    decodes it and uses `withExtractedContext` to set up the span
    parent.

### What the adapters do today

Both adapters share a similar shape:

-   A `Convert.hs` module turns the broker-native message into an
    `Envelope`. Both adapters' `Convert.hs` have a function called
    `extractTraceHeaders` that picks `traceparent` and (optionally)
    `tracestate` out of the message headers and returns a `Maybe
    TraceHeaders`. Both populate `Envelope.traceContext` with that.
-   An `Internal.hs` (Kafka)/`Internal.hs` (pgmq) module wires the
    polling loop and the `AckHandle` finalize logic. Neither
    creates spans; both rely on `processOne` to do that.
-   pgmq stops there. Its public module
    `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq.hs` does **not**
    open any spans of its own.
-   Kafka adds an opt-in module
    `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs`
    exposing one function:
    `traced :: TopicName -> Stream (Eff es) (Ingested es v) -> Stream
    (Eff es) (Ingested es v)`. This rewrites each `Ingested.ack`
    so its `finalize` opens a Consumer-kind span named
    `"<topic> process"` parented on
    `Envelope.traceContext`, populates the messaging attributes
    (`messaging.system="kafka"`, `messaging.destination.name=<topic>`,
    `messaging.operation="process"`,
    `messaging.message.id=<envelope.messageId>`) plus the
    Kafka-specific typed attributes
    (`messaging.kafka.destination.partition`,
    `messaging.kafka.message.offset`) when they parse out of the
    envelope, then calls the original `finalize`. See
    `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs:84-101`.

The Kafka demo
`shibuya-kafka-adapter/shibuya-kafka-adapter-jitsurei/app/OtelDemo.hs`
uses `traced` *without* `runApp` — it folds the adapter's source
stream by hand and calls `finalize AckOk` inline. This is why the
double-span condition described in Surprise S2 has not bitten the
existing Jaeger verification.

### What the framework does today on the consume path

`shibuya-core/src/Shibuya/Runner/Supervised.hs:360-468` defines
`processOne`, the per-message body that the supervised runner calls
for each `Ingested es msg` arriving on the bounded inbox. It:

1.  Decodes `envelope.traceContext` into a `Maybe SpanContext` via
    `Shibuya.Telemetry.Propagation.extractTraceContext`. (line 371)
2.  Calls `withExtractedContext parentCtx $
    withSpan' (processSpanName pidText) consumerSpanArgs $ \\traceSpan
    -> ...` (lines 374–375). The span name is built from
    `ProcessorId pidText`, e.g. `"orders process"`.
3.  Sets four `messaging.*` attributes
    (`messaging.system="shibuya"`, `messaging.destination.name=pidText`,
    `messaging.operation="process"`, `messaging.message.id=msgIdText`).
    (lines 378–381)
4.  Optionally sets `shibuya.partition` from
    `envelope.partition`. (lines 384–386)
5.  Sets `shibuya.inflight.count` and `shibuya.inflight.max` from
    the metrics state. (lines 401–402)
6.  Emits `shibuya.handler.started` event. (line 405)
7.  Catches handler exceptions via `catchAny`, calls
    `recordException` and stashes a `HandlerException` error.
    (lines 408–418)
8.  Emits `shibuya.handler.completed` (or `eventAckDecision` on
    error) and sets `shibuya.ack.decision`. (lines 421–442)
9.  Sets the span's status from the `AckDecision`. (lines 432–443)
10. Decrements inflight count and updates stats. (lines 446–447)
11. On `AckHalt`, sets the haltRef so the stream loop exits. (line
    451)

The span explicitly wraps both `handler ingested` (line 411) and
`ingested.ack.finalize decision` (line 412), so the Kafka adapter's
`traced` wrapper, when it fires inside `processOne`, opens its own
inner span around just `finalize`. This is the double-span condition
in S2.

### What is *not* covered by `processOne`

-   The ingester's poll loop. `Shibuya/Runner/Ingester.hs:39-60`
    runs the adapter's source stream with a metrics counter; it
    does **not** open any span. Errors thrown by the source stream
    (e.g., a Postgres connection drop in pgmq, a fatal Kafka error
    from `pollMessageBatch`) are not visible in traces today.
-   Adapter shutdown. `Adapter.shutdown` is invoked from
    `Shibuya/App.hs:241-258` during graceful shutdown but is not
    span-wrapped.
-   Adapter-side DLQ writes. The pgmq adapter's
    `mkAckHandle (AckDeadLetter reason)` branch
    (`shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:201-252`)
    sends the message body to the DLQ via
    `sendMessageWithHeaders` or `sendMessage`. The original
    message's headers (including the original producer's
    `traceparent`) are forwarded verbatim, so the DLQ message
    still carries the **original producer's** trace context. The
    consumer of the DLQ will therefore see its own consumer span
    parented on the original producer, **not** on the failing
    consumer's processOne span. This may be intentional ("the
    failure is logically attributed to the producer's trace") or
    accidental ("we forgot to inject the consumer's traceparent");
    M1.2 must say which.

### Test entry points

-   `cabal test shibuya-core-test` runs in
    `shibuya-core/test/`. The most relevant tests are
    `Shibuya.Telemetry.EffectSpec`,
    `Shibuya.Telemetry.PropagationSpec`,
    `Shibuya.Telemetry.SemanticSpec`. The last drives `processOne`
    through `runWithMetrics` against an in-memory exporter and
    asserts span/attribute names. It is the closest existing
    template for any new test added by M2/M3.
-   `cabal test shibuya-kafka-adapter-test` runs in
    `shibuya-kafka-adapter/shibuya-kafka-adapter/test/`. The
    relevant test is
    `Shibuya.Adapter.Kafka.TracingTest`, which inlines a tiny
    in-memory `SpanProcessor` (the package
    `hs-opentelemetry-exporter-in-memory` is currently unused in
    the kafka-adapter test stanza).
-   `cabal test shibuya-pgmq-adapter-test` runs in
    `shibuya-pgmq-adapter/shibuya-pgmq-adapter/test/`. There is no
    tracing-specific spec yet; the relevant audit-time check is
    that `Shibuya.Adapter.Pgmq.ConvertSpec` and
    `Shibuya.Adapter.Pgmq.ChaosSpec` cover trace-header round-trip
    and DLQ trace preservation respectively.

### A glossary of terms used below that are not ordinary English

-   **Ack / `AckDecision`** — the handler's verdict on a message:
    `AckOk`, `AckRetry RetryDelay`, `AckDeadLetter
    DeadLetterReason`, `AckHalt HaltReason`. The framework calls
    `ingested.ack.finalize decision` inside `processOne` to apply
    that verdict to the queue.
-   **DLQ** — dead-letter queue. When a handler returns
    `AckDeadLetter`, the adapter forwards the message to a
    configured "graveyard" queue rather than letting the broker
    redeliver it.
-   **Lease** — for adapters with visibility-timeout semantics
    (pgmq), a handle the handler can use to extend the timeout
    while it is still working. Kafka has no lease (`Nothing`).
-   **`SpanKind`** — a tag on a span saying what role it plays in a
    distributed trace. Shibuya uses `Consumer` for the per-message
    processing span. The spec defines `Producer`, `Consumer`,
    `Server`, `Client`, `Internal`.
-   **`processSpanName`** — the helper from
    `Shibuya.Telemetry.Semantic` that produces the span name string
    `"<destination> process"` per the spec recommendation.


## Plan of Work

### Milestone 1 — Audit, write up findings, decide priorities

**Scope.** Read-only investigation. Produce a single new file,
`docs/plans/9-otel-audit-findings.md`, that names every issue
identified, cites it with file paths and line numbers, ranks each
issue P0/P1/P2, and proposes a fix in one paragraph. No code
changes in this milestone.

**What will exist at the end.** A committed
`docs/plans/9-otel-audit-findings.md` whose first paragraph names
the audit scope (the four buckets in the third Decision Log entry)
and whose body has one section per finding. Surprises S1..S7 above
are the audit's starting hypotheses; the milestone confirms,
refutes, or refines each one.

**What to read.** In order:

1.  `shibuya-core/src/Shibuya/Telemetry.hs` and every module it
    re-exports.
2.  `shibuya-core/src/Shibuya/Runner/Supervised.hs` (the only
    consumer of the `Tracing` effect inside the framework).
3.  `shibuya-core/src/Shibuya/Runner/Ingester.hs` (to confirm the
    poll loop is not span-wrapped).
4.  `shibuya-core/src/Shibuya/App.hs` (to confirm `runApp` does not
    bracket tracing initialization, and that `TracingConfig` is
    unused in the framework).
5.  `shibuya-core/src/Shibuya/Core/Types.hs` (the `Envelope` and
    `TraceHeaders` types).
6.  `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs` and
    `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`,
    paying particular attention to the `mkAckHandle (AckDeadLetter
    _)` branch and whether DLQ writes carry the consumer's trace
    context or the original producer's.
7.  `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs`,
    `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`,
    and `shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs`.
    Confirm Surprise S2 by reading the two `withSpan'` call sites
    (one in `Tracing.hs`, one in `Supervised.hs`).
8.  The four tests
    `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs`,
    `shibuya-core/test/Shibuya/Telemetry/EffectSpec.hs`,
    `shibuya-core/test/Shibuya/Telemetry/PropagationSpec.hs`, and
    `shibuya-kafka-adapter/shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs`,
    to understand how the two repos exercise tracing today.
9.  The historical plans
    `docs/plans/OPENTELEMETRY_INTEGRATION.md`,
    `docs/plans/PGMQ_OPENTELEMETRY_INSTRUMENTATION.md`,
    `docs/plans/2-align-opentelemetry-semantic-conventions.md`,
    `shibuya-kafka-adapter/docs/plans/8-investigate-hw-kafka-client-instrumentation.md`,
    `shibuya-kafka-adapter/docs/plans/9-add-shibuya-kafka-tracing-module.md`,
    `shibuya-kafka-adapter/docs/plans/10-align-kafka-adapter-otel-semantic-conventions.md`.
    Any finding that was deliberately decided in one of these
    plans must say so explicitly with a citation.

**Findings template.** For each finding the audit document writes:

    ### Finding F<n>: <one-line title>

    Bucket: A | B | C | D (per Decision Log entry 3).
    Severity: P0 | P1 | P2.
    Evidence: <file:line citations, 1-3 lines max>.

    What it is: <one short paragraph>.
    Why it matters: <one short paragraph>.
    Proposed fix: <one short paragraph; concrete, names the file>.
    Alternatives considered: <one short paragraph or N/A>.
    Prior decisions: <citations to plans, or "none">.

**Severity calibration.** P0 = correctness or double-counting bug
that distorts the trace shape under normal use (S2 is the obvious
candidate). P1 = silent loss of information or strong API friction
that drives users to write boilerplate (S3, S4, the producer/DLQ
gap). P2 = polish (S1, S6).

**Acceptance.** The findings file exists, every Surprise S1..S7 has
been turned into either a confirmed Finding F<n> or an explicit
"refuted: <evidence>" line, and the file's Triage table at the top
ranks every Finding by severity with a one-cell summary. M2 and M3
read this table to decide what to implement.

Commands at end of milestone (working directory
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`):

    git add docs/plans/9-audit-and-improve-opentelemetry-api.md \
            docs/plans/9-otel-audit-findings.md
    nix fmt
    git commit  # message below

Commit message:

    docs(plans): record OTel API audit findings (plan 9, M1)

    Read-only audit of the shibuya-core OpenTelemetry surface and
    its two real consumers (shibuya-pgmq-adapter,
    shibuya-kafka-adapter). Captures findings with file:line
    evidence and triage ranking; no code changes.

    ExecPlan: docs/plans/9-audit-and-improve-opentelemetry-api.md
    Intention: intention_01kh0akd82ekat0be54p2f72kv

### Milestone 2 — Implement P0 fix(es)

**Scope.** Whatever M1 ranked P0. The most likely candidate at
plan-creation time is Surprise S2 (the double-span condition between
`Shibuya.Adapter.Kafka.Tracing.traced` and `processOne`). The
implementation is gated on M1's verification — if S2 turns out
not to be a real issue under `runApp`, M2 picks the next-highest
Finding.

**If the P0 is S2 (double-span)**, the candidate fixes are, in rough
order of preference:

1.  **Make the framework's per-message span the only one, and let
    the adapter contribute attributes to it.** Add a new optional
    field on `Envelope`, e.g.
    `attributes :: !(Maybe (HashMap Text Attribute))`, populated
    by the adapter's `Convert.hs`. `processOne` reads it after
    opening the span and calls `addAttributes traceSpan attrs`.
    The Kafka adapter's `traced` module is then either deleted (if
    it adds nothing beyond what `Envelope.attributes` carries) or
    reduced to a populator for `Envelope.attributes` only — no
    span, no `withSpan'`, no risk of double-counting. Tests in M2
    must run a runApp-style scenario through both adapters'
    `traced`+ `processOne` paths and assert exactly one Consumer
    span per message, with the union of spec-aligned and
    adapter-specific attributes on it.
2.  **Document `traced` as mutually exclusive with `runApp`.** If
    the audit determines that `traced` is intended only for the
    raw-stream case (the OtelDemo path) and the double-counting is
    only a documentation problem, M2 instead adds a Haddock note
    on `traced` and on `runApp` saying so, and a runtime check (a
    `assert :: Tracing :> es => ...` in `traced` that complains if
    invoked under `runApp` — though in practice we have no signal
    distinguishing the two scopes, so this option is weak).
3.  **Have `traced` detect the inner-span case and skip.**
    `OpenTelemetry.Context.lookupSpan` on the thread-local context
    returns the current active span, if any. `traced` could check
    that and, if a span of the same name is already active, leave
    the `AckHandle` alone. This is brittle (relies on span-name
    equality) and is mentioned only for completeness.

The first option is the cleanest and is the recommended starting
point unless M1 turns up evidence the audit missed.

**What will exist at the end.** A code change set across one or
more of `shibuya-core`, `shibuya-pgmq-adapter`,
`shibuya-kafka-adapter` that fixes the named P0 with a passing
test. The change is committed across one or more `git commit`s,
each carrying both `ExecPlan:` and `Intention:` trailers.

**Acceptance.** All three repos build. The P0's accompanying test
fails on the pre-fix code and passes on the post-fix code (a
`git stash; cabal test; git stash pop` red/green cycle is the
gold standard, recorded in Surprises). The Jaeger smoke
(`just process-up`, produce a message, watch the trace) shows
exactly one Consumer-kind span per processed message.

### Milestone 3 — Implement P1 fix(es)

**Scope.** Same as M2 but for everything M1 ranked P1. The likely
candidates at plan-creation time:

-   **DLQ trace propagation (Surprise S2's twin on the produce
    side)** — if M1.2 confirms that pgmq's DLQ write forwards the
    *original producer's* `traceparent` rather than injecting the
    *consumer's*, the right fix is to add `Shibuya.Telemetry.Propagation`
    helpers usable from inside an adapter's `mkAckHandle`, and to
    use them in
    `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs`'s
    `AckDeadLetter` branch. The new headers replace or augment the
    forwarded `traceparent`; the decision (replace vs. augment) is
    a Decision Log entry to be made in M3 with an explicit
    rationale referencing what
    `docs/plans/PGMQ_OPENTELEMETRY_INSTRUMENTATION.md` says about
    DLQ trace preservation.
-   **`runApp` does not bracket tracing initialization (S5)** — add
    a `runAppTraced :: TracingConfig -> ...` helper in
    `shibuya-core/src/Shibuya/App.hs` that brackets
    `initializeGlobalTracerProvider`/`shutdownTracerProvider`
    and feeds the `Tracer` to `runTracing`. Update
    `shibuya-pgmq-example` and the Kafka jitsurei `OtelDemo` to use
    it, and document the wiring in `docs/plans/OPENTELEMETRY_INTEGRATION.md`.
-   **Ingester polling errors are invisible (gap noted in
    "What is *not* covered by `processOne`")** — if M1 elevates
    this to P1, add an `ingestSpanName`-named span in
    `runIngesterWithMetrics` that scopes the source-stream
    consumption. Cost-aware: the span must close after the
    *stream* exits, not per-message; per-message would dwarf
    `processOne`'s span count.

The exact set lands as it lands; M3 picks them in order.

**Acceptance.** Every P1 has a passing test plus, where externally
observable, a Jaeger-shape diff in
`docs/plans/9-otel-audit-findings.md`'s Surprises section.

### Milestone 4 — Refresh the legacy plan and close out

**Scope.**

1.  Update `docs/plans/OPENTELEMETRY_INTEGRATION.md` so its
    "Current state" matches reality at the end of M3. The legacy
    plan's "Implementation Phases" already happened; mark it
    superseded for any section that no longer matches. Do not
    delete it — it is the design archive.
2.  Run the local gates on all three repos:

        # In /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
        nix fmt
        nix flake check
        cabal build all
        cabal test shibuya-core-test

        # In /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter
        nix flake check
        cabal build all
        cabal test shibuya-pgmq-adapter-test

        # In /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-kafka-adapter
        nix flake check
        cabal build all
        cabal test shibuya-kafka-adapter-test

3.  Fill in the Outcomes & Retrospective section of this plan.

**Acceptance.** All gates clean. Outcomes section names every
landed Finding by F<n> and the commit it landed in. Anything
left un-landed is recorded under "Gaps" with a one-line reason
and, if applicable, a follow-up plan filename.


## Concrete Steps

Working directory for every command is
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` unless
otherwise noted.

### Bootstrapping

    git status   # Expected: only "?? .agents/" or similar untracked
    git rev-parse --abbrev-ref HEAD   # Expected: master

### Milestone 1

The audit is read-only. The only "build" step is the editor.

    # 1. Create the findings document.
    $EDITOR docs/plans/9-otel-audit-findings.md

    # 2. Read every file listed under "Plan of Work / Milestone 1 /
    #    What to read" and produce one Finding per Surprise (S1..S7),
    #    refuting or confirming each. Add new Findings for anything
    #    discovered along the way that is not in S1..S7.

    # 3. Commit.
    git add docs/plans/9-audit-and-improve-opentelemetry-api.md \
            docs/plans/9-otel-audit-findings.md
    nix fmt
    git commit  # message: see "Plan of Work / Milestone 1 / Commands"

### Milestone 2 (template; exact files depend on M1)

If the P0 is S2 with the recommended fix (Envelope-attribute hook):

    # In shibuya-core:
    $EDITOR shibuya-core/src/Shibuya/Core/Types.hs        # add `attributes` field
    $EDITOR shibuya-core/src/Shibuya/Runner/Supervised.hs # call addAttributes
    $EDITOR shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs # extend test

    cabal build shibuya-core
    cabal test  shibuya-core-test
    nix fmt

    git add shibuya-core/...
    git commit  # ExecPlan + Intention trailers

    # In shibuya-pgmq-adapter (separate repo, separate commit):
    cd ../shibuya-pgmq-adapter
    $EDITOR shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Convert.hs

    cabal build all
    cabal test shibuya-pgmq-adapter-test
    nix fmt

    git add ...
    git commit

    # In shibuya-kafka-adapter (separate repo, separate commit):
    cd ../shibuya-kafka-adapter
    $EDITOR shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Convert.hs
    $EDITOR shibuya-kafka-adapter/src/Shibuya/Adapter/Kafka/Tracing.hs  # may shrink to deletion
    $EDITOR shibuya-kafka-adapter/test/Shibuya/Adapter/Kafka/TracingTest.hs

    cabal build all
    cabal test shibuya-kafka-adapter-test
    nix fmt

    git add ...
    git commit

### Milestone 3 (template; exact files depend on M1)

Each P1 lands as its own commit per repo, same shape as M2.

### Milestone 4

    nix fmt
    nix flake check
    cabal build all
    cabal test shibuya-core-test

    cd ../shibuya-pgmq-adapter && nix flake check && cabal test shibuya-pgmq-adapter-test
    cd ../shibuya-kafka-adapter && nix flake check && cabal test shibuya-kafka-adapter-test
    cd ../shibuya

    $EDITOR docs/plans/OPENTELEMETRY_INTEGRATION.md   # mark superseded sections
    $EDITOR docs/plans/9-audit-and-improve-opentelemetry-api.md
    # Fill Outcomes & Retrospective.

    git add docs/plans/OPENTELEMETRY_INTEGRATION.md \
            docs/plans/9-audit-and-improve-opentelemetry-api.md
    git commit


## Validation and Acceptance

End-to-end validation differs per milestone.

**M1.** Acceptance is the existence of
`docs/plans/9-otel-audit-findings.md` with the Triage table at the
top, every Finding cited with at least one file:line, and every
Surprise S1..S7 either confirmed-as-Finding or refuted with
evidence. A reader who reads only the findings file should be able
to predict, within reason, the M2 and M3 milestones. There is no
runtime check at this stage — the audit is a written deliverable.

**M2 / M3.** For any landed Finding that affects span shape,
attribute set, span name, or parent linkage:

1.  The accompanying HSpec or HUnit test (in
    `shibuya-core/test/Shibuya/Telemetry/SemanticSpec.hs` for
    framework changes, in
    `shibuya-pgmq-adapter/.../test/Shibuya/Adapter/Pgmq/...Spec.hs`
    for pgmq adapter changes, in
    `shibuya-kafka-adapter/.../test/Shibuya/Adapter/Kafka/TracingTest.hs`
    for Kafka adapter changes) drives the affected code path
    through an in-memory exporter and asserts the exact wire-name
    of every changed attribute, the exact span name, and the
    parent linkage. The test must fail on the pre-fix code and
    pass on the post-fix code; the Surprises section records both
    transcripts.

2.  Where externally observable, a Jaeger smoke check is run:

        # Only relevant for the kafka or pgmq adapter changes.
        # Working directory: the adapter repo whose flake.nix
        # configures process-compose for jaeger.
        just process-up

        # Then publish a message with a known traceparent and run
        # the demo executable; example for kafka:
        rpk topic produce orders --key k1 \
            -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
            <<< 'hello-otel'
        cabal run otel-demo

        curl -s "http://127.0.0.1:16686/api/traces/0af7651916cd43dd8448eb211c80319c" \
          | jq '.data[0].spans | map({operationName, references, tags: (.tags | map({key, value}))})'

    The acceptance observation is named in the Finding's "Proposed
    fix" line: a specific span count, a specific attribute, an
    absent attribute, or a specific parent reference. For example,
    if the P0 is S2's recommended fix, acceptance is "exactly one
    Consumer-kind span per processed message, named
    `<topic> process`, carrying both the spec-aligned messaging
    attributes and the Kafka-typed
    `messaging.kafka.destination.partition` /
    `messaging.kafka.message.offset` attributes".

**M4.** Acceptance is the green local-gates run named in the
milestone, plus a filled-out Outcomes & Retrospective.


## Idempotence and Recovery

The audit milestone (M1) is fully idempotent: re-reading the source
files and re-rewriting the findings document converges on the same
state. If the audit document is lost, regenerating it from the same
file list is safe.

The implementation milestones (M2/M3) edit code across three
separate cabal packages in three separate git repos. Each repo's
edits are independent on the file system and can be rolled back
with `git revert` per repo without affecting the others. The two
cross-repo invariants to preserve are:

-   `shibuya-pgmq-adapter` and `shibuya-kafka-adapter` both depend
    on `shibuya-core ^>=0.4`. If M2 or M3 require bumping
    `shibuya-core`'s version (for example, by adding a field to
    `Envelope`), the bump must be a minor (`0.5.x`) and both
    adapters must update their `^>=` bound in the same milestone.
    The cabal package on Hackage is the single point of truth; do
    not introduce path-based pins to "test" the integration before
    publishing.
-   The `Envelope` record is `derive stock (... Functor ...)`. Any
    new field must be a non-functor field (i.e., not `... msg`)
    or the `Functor` instance breaks. New fields should be
    additive, with `Maybe` or `Monoid` defaults so existing
    constructors compile after the bump.

If a hook fails on commit (the project's `CLAUDE.md` warns about
treefmt), the recovery is the standard `nix fmt`, re-stage,
recommit dance.


## Interfaces and Dependencies

Packages used by this work:

-   `hs-opentelemetry-api ^>=0.3` (already a dependency of every
    relevant cabal stanza in all three repos). Provides `Span`,
    `SpanContext`, `Tracer`, `Attribute`, `AttributeKey`.
-   `hs-opentelemetry-semantic-conventions ^>=0.1` (already a
    dependency of `shibuya-core` and
    `shibuya-kafka-adapter`). Adapters that need typed
    broker-specific keys depend on this.
-   `hs-opentelemetry-propagator-w3c ^>=0.1` (already a dependency
    of `shibuya-core`).
-   `hs-opentelemetry-exporter-in-memory ^>=0.0` (already a
    test-stanza dependency of `shibuya-core`). Used by any new
    test that needs to capture spans.
-   No new dependencies are anticipated by this plan. If M2/M3
    require one, that is a Decision Log entry.

Interface shape after each milestone:

-   End of M1: no API change. New file
    `docs/plans/9-otel-audit-findings.md`.
-   End of M2: depends on the fix landed. If the fix is the
    `Envelope.attributes` hook, the change is
    in `shibuya-core/src/Shibuya/Core/Types.hs`:

        data Envelope msg = Envelope
          { messageId    :: !MessageId
          , cursor       :: !(Maybe Cursor)
          , partition    :: !(Maybe Text)
          , enqueuedAt   :: !(Maybe UTCTime)
          , traceContext :: !(Maybe TraceHeaders)
          , attempt      :: !(Maybe Attempt)
          , attributes   :: !(Maybe (HashMap Text Attribute))   -- NEW
          , payload      :: !msg
          }

    and a corresponding `addAttributes traceSpan` call in
    `shibuya-core/src/Shibuya/Runner/Supervised.hs::processOne`. The
    Kafka adapter's `Tracing.hs` either disappears or shrinks to a
    `populateAttributes :: Envelope v -> Envelope v` helper that
    sets the `attributes` field; the `Stream.mapM` /
    `withSpan'` body is gone.
-   End of M3: depends on which P1s landed. Most likely candidates:

        -- DLQ trace injection
        -- shibuya-core/src/Shibuya/Telemetry/Propagation.hs (if
        -- not already present):
        currentTraceHeaders :: (Tracing :> es, IOE :> es) => Eff es TraceHeaders

        -- A runApp helper that brackets the tracer:
        -- shibuya-core/src/Shibuya/App.hs:
        runAppTraced
          :: (IOE :> es)
          => TracingConfig
          -> SupervisionStrategy
          -> Int
          -> [(ProcessorId, QueueProcessor (Tracing : es))]
          -> Eff es (Either AppError (AppHandle (Tracing : es)))

    The exact signatures are decided in the Decision Log when
    the work lands.

-   End of M4: no further interface change. Outcomes section
    summarises landed work.

No new public API in `shibuya-core` should ever land without a
matching update to `docs/plans/OPENTELEMETRY_INTEGRATION.md`'s
"Quick Start" or "Configuration" sections so the legacy plan stays
in sync.

---

Revision history:

-   2026-05-05: Initial draft. Scoped to (a) audit Shibuya's OTel
    API and (b) implement the highest-priority improvements that
    fall out of the audit. Intention
    `intention_01kh0akd82ekat0be54p2f72kv` attached. Surprises
    S1..S7 are the audit's pre-implementation hypotheses,
    targeting the consume-side and produce-side seams between
    `shibuya-core` and the two real adapters
    (`shibuya-pgmq-adapter`, `shibuya-kafka-adapter`).
