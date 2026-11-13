---
id: 56
slug: link-every-batch-member-s-creation-context-from-the-batch-span
title: "Link every batch member's creation context from the batch span"
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
      at: 2026-11-13T00:43:42Z
      mode: "implement"
      note: "Implement batch fan-in links, gate and docs"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:42:29Z
      verdict: "changes-requested"
      note: "Resolve overflow count versus decode cap and root helper prerequisite; corrected release sequence."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-12T18:51:06Z
      verdict: "comments"
      note: "Follow-up: planning findings resolved; document checks pass; dependency, adapter and runtime validation remain implementation prerequisites."
---

# Link every batch member's creation context from the batch span

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

When Shibuya processes messages in batches, it opens one OpenTelemetry span around the whole
batch. Today that span is made a child of whichever span produced the *first* message in the
batch, and the other members' producers are forgotten. A batch of 100 messages from 100
different requests appears in one request's trace and is invisible from the other 99.

After this change the batch span is a root span that carries a *link* (OpenTelemetry's pointer
from one span to another causally related span, without joining its trace) to the creation
context of every member, up to a fixed bound, each link labelled with that member's message
identifier. From any producer's trace, a backend that follows
links can reach the batch that processed its message. This is what the OpenTelemetry messaging
conventions prescribe for batches, since a span can have only one parent.

Someone can see it working in the test suite: a batch built from messages with three distinct
`traceparent` headers yields one batch span with no parent and three links, each naming its
message. The change must not slow down or leak: the link list is bounded regardless of batch
size, built strictly, and holds no reference to the messages beyond their identifiers.


## Progress

- [x] M1 (2026-11-12): Batch spans are roots with one link per member that has a creation context, each
  carrying `messaging.message.id`, bounded at 128, plus `messaging.batch.message_count`; `shibuya-core/test/Shibuya/Telemetry/BatchCorrelationSpec.hs`
  passes along with the rest of `cabal test shibuya-core`. Evidence: 14 new examples; all four
  `shibuya-core` suites pass (354 examples), and `shibuya-metrics-test` passes.
- [ ] M2: Performance and retention gate passed against the baseline commit for the
  `tracing/batch100/*` cells and a new large-batch cell; retention suite covers batch links.
- [ ] M3: User guide, capability document, changelog and the correlation ADR describe batch
  behaviour; parent MasterPlan updated.


## Surprises & Discoveries

Review resolved (2026-11-12): overflow accounting scans and decodes the full batch, counting
only valid omitted contexts. Retained links are bounded at 128; scan and decode work are not
constant. Plan 55 Complete supplies the root-context helper under a single owner.

- The pinned `hs-opentelemetry-semantic-conventions` names the key `messaging_batch_messageCount`
  (`AttributeKey Int64`, wire name `messaging.batch.message_count`), not
  `messaging_batch_message_count`. `attrMessagingBatchMessageCount` uses it.
- The collector folds over the batch `NonEmpty` directly, as the plan preferred, through
  `collectBatchLinksBy :: Foldable t => (a -> MessageId) -> (a -> Maybe TraceHeaders) -> t a -> BatchLinks`.
  `collectBatchLinks` over pairs remains for unit tests. The raw-header reuse described in the
  Decision Log is built in: equal header lists reuse the previous member's decoded context.
- The fixed-header `batch100` cells compare one list against an identical list per member, so
  they decode once per batch, as the baseline did, and build 100 links.
- M2 allocation gate (2026-11-12, against `40d112d`, plan 55's final commit). All per-run, 10,000
  messages:
  - `batch100/enabled-headers`: 24,430,713 → 30,680,957, about +625 bytes per member. Each
    member gets a `NewLink`, a one-entry attribute map with its message id, a list cell, and the
    SDK's frozen `Link` copy. The baseline decoded one header per batch and built no link.
  - `batch100/enabled-headers-distinct` (new): 34,068,690, about 339 bytes per member more than
    the fixed-header cell. That is the decode of 100 distinct headers per batch, consistent with
    plan 54's ≈346-byte decode.
  - `batch1000/enabled-headers-distinct` (new): 28,393,426, *below* the batch100 distinct cell. It
    decodes all 10,000 headers but stores 128 links per batch (1,280 in total, against 10,000).
    The link bound holds at the cost level.
  - `batch100/enabled-noheaders`: +34,637, about 346 bytes per batch: the root-context attachment
    and the `messaging.batch.message_count` entry, as the contract allows.
  - `batch100/disabled-*`: −53,529 and −142,157. The disabled path no longer decodes the first
    member's header.
  - Single-message serial cells and pre-existing serial groups are within 0.3%. Async and
    `concurrency-modes` cells moved ±2–10% in both directions, as they did in plan 55's runs;
    their allocation depends on scheduling.
- M2 time gate: unreadable on this run. Load average reached 29.5 while another session ran a
  load benchmark (`en-server-*`, about 950% CPU) and GHC builds. Every group, including the pure
  streamly baselines, failed by 12–210%. The time comparison is to be repeated when the machine
  is quiet (FRIC-2).


## Decision Log

- Decision: Batch spans take no parent from any member and this is not configurable.
  Rationale: Any single parent misattributes the batch. The adapter's `TraceCorrelation` policy
  governs single-message processing only.
  Date: 2026-11-11

- Decision: At most 128 links per batch span; members beyond that are counted in a span
  attribute rather than linked.
  Rationale: 128 is the OpenTelemetry SDK's default link limit per span. Bounding the list
  ourselves keeps memory per span constant for any batch size and avoids relying on the SDK for this bound. A lower configured SDK limit may
  independently drop links; Shibuya's counter measures only its own omitted valid members.
  Date: 2026-11-11

- Decision: One link per member that has a creation context, each carrying that member's
  `messaging.message.id`; members sharing a context are not collapsed. The batch span also
  carries `messaging.batch.message_count`.
  Rationale: The OpenTelemetry messaging conventions say that for a batch, attributes whose
  values vary per message "SHOULD" be set "on links describing individual messages", and their
  batch example puts `messaging.message.id` on each link and `messaging.batch.message_count` on
  the span. Collapsing members that share a context, considered in an earlier draft, would drop
  the second member's identifier. The cost of repeated contexts is handled instead by reusing
  the previous member's decoded context when the raw header bytes are equal.
  Date: 2026-11-11

- Decision: The batch span neither takes nor links the thread's ambient context.
  Rationale: Same reasoning as for single messages in plan 55: on Shibuya's processing threads
  the current context is incidental, not an operation that caused the batch.
  Date: 2026-11-11


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

This plan is the third child of
`docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md`. Two prerequisites
must be in the working tree:

- `docs/plans/54-establish-tracing-enabled-performance-and-retention-baselines.md` Complete: it
  provides the benchmark group `tracing` (cells `tracing/batch100/…`) in
  `shibuya-core-bench/bench/Bench/Tracing.hs` and the test suite
  `shibuya-core-trace-retention-test` in `shibuya-core/test-retention/`.
- All of
  `docs/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md`
  Complete: it provides `withRootContext` from M2 and the module `Shibuya.Telemetry.Correlation` with
  `creationLinkWith :: AttributeMap -> TraceHeaders -> Maybe NewLink` (decodes W3C trace headers
  into a link holding a fully evaluated span identity and the supplied link attributes) and
  `consumerSpanArgsLinkedTo :: [NewLink] -> SpanArguments` (Consumer-kind span arguments
  carrying links).

If plan 55 is not Complete or its required helpers are missing, stop. Its final commit is
this plan's benchmark baseline, isolating the batch change.

Shibuya is a Haskell queue-processing framework; the library package is `shibuya-core`. A
*batching processor* (`BatchingProcessor`, built with `mkBatchProcessor`, configured by
`BatchConfig` in `shibuya-core/src/Shibuya/Batch.hs`, default `batchSize = 100`) groups incoming
messages and hands each group to a batch handler. Each message is an `Ingested` wrapping an
`Envelope` (`shibuya-core/src/Shibuya/Core/Types.hs`); `Envelope.traceContext :: Maybe
TraceHeaders` carries the producer's W3C `traceparent` header pair when the adapter found one.

The code to change is in `shibuya-core/src/Shibuya/Internal/Runner/BatchProcessor.hs`.
`processOneBatchWithDetail` first asks each member whether its delivery is still current and
drops superseded members (see ADR 0013 below), then calls `processCurrentBatchWithDetail` with
the surviving `NonEmpty (Ingested es msg)`. That function begins:

```haskell
-- Use the first message's trace context as the batch span's parent. A batch
-- may span several traces; picking the first is a pragmatic single parent
-- (full fan-in links are a later refinement).
let firstMsg = NE.head batch
    parentCtx = firstMsg.envelope.traceContext >>= extractTraceContext
withExtractedContext parentCtx $
  withSpan' (processSpanName pidText) consumerSpanArgs $ \traceSpan -> do ...
```

`withExtractedContext` and `withSpan'` are in `shibuya-core/src/Shibuya/Telemetry/Effect.hs`;
`withSpan'` does nothing but pass a sentinel span when tracing is disabled, and
`isTracingEnabled` reports the mode. Plan 55 owns `withRootContext`, which temporarily attaches
an empty context. Consume it unchanged; do not define a second implementation here.

Batch span attributes such as `shibuya.batch.size` are named in
`shibuya-core/src/Shibuya/Telemetry/Semantic.hs`, which takes the spec-defined attribute names
from the generated `OpenTelemetry.SemanticConventions` module (for example
`attrMessagingMessageId = unkey Sem.messaging_message_id`). The batch span does not currently
set the spec attribute `messaging.batch.message_count`.

What the OpenTelemetry messaging conventions say about batches (the document
`docs/messaging/messaging-spans.md` in `open-telemetry/semantic-conventions`, status
Development, read in full on 2026-11-11): "For each message it accounts for, the "Process" or
"Receive" span SHOULD link to the message's creation context."; using the creation context as
parent is allowed "Exclusively for single messages scenarios"; links are "the only option to
correlate producer and consumer(s) in batch scenarios"; when an attribute has the same value for
all messages "the instrumentation SHOULD set such attribute on the span representing the batch
operation", and "If the attribute values vary, the instrumentation SHOULD set such attributes on
links describing individual messages." The document's batch example shows a span with
`messaging.batch.message_count` and one link per message carrying `messaging.message.id`.

Relevant ADRs.
[ADR 0013](../adr/0013-let-adapters-supersede-a-delivery-before-its-handler-runs.md): superseded
members are removed before the batch span is opened; links must be computed from the surviving
members only, which is what `processCurrentBatchWithDetail` receives.
[ADR 0012](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md):
the framework owns the processing span; disabled tracing does no per-message work.
[ADR 0006](../adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md):
an allocation increase is a regression even when time is within noise.
Update [ADR 0014](../adr/0014-define-consumer-correlation-and-bounded-batch-link-accounting.md) with this plan's
implementation and validation evidence; keep its status honest about remaining work.

The performance and retention contract from the parent MasterPlan, as it applies here:

1. With tracing disabled, no header is decoded and no list is built; the batch path is as it
   was.
2. With tracing enabled, retained links are capped at 128. Exact valid overflow counts
   require scanning all members and decoding their headers, so work and transient decode
   allocation scale with batch size and header length. Root attachment and batch-count
   attributes are additional explained costs even without headers.
3. The link list is fully evaluated before the span is created and holds only evaluated span
   identities and evaluated message-identifier text, never an `Ingested`, `Envelope`, payload,
   or the batch `NonEmpty`.
4. Heap residency under sustained batch processing stays flat.


## Plan of Work

### Milestone 1: fan-in links

In `processCurrentBatchWithDetail`, replace the first-member parent with a link list.

Check `isTracingEnabled` first. When disabled, call the existing body through `withSpan'` with
the constant `consumerSpanArgs` and do not traverse the batch for headers.

When enabled, make one strict left-to-right pass over the batch that accumulates, with strict
accumulators: the links collected so far (in reverse, reversed once at the end), their count,
and a count of members not linked because the bound was reached. For each member that has a
decodable `traceContext`: before the cap, build the link with `creationLinkWith`, passing a
one-entry attribute map of `messaging.message.id` to the member's message identifier text, and
cons it. After 128 links, use `extractTraceContext` to validate each remaining context and
increment the dropped count only on successful decoding; construct no further links or
attribute maps. Skip absent and malformed contexts everywhere. Evaluate each link and its attribute map
before it enters the list; the map must hold the identifier `Text` itself, not a thunk that
projects it out of the envelope. Members that share a creation context each get their own link,
since the links differ in message identifier. Put this in a small pure, top-level function in
`Shibuya.Telemetry.Correlation` (signature in Interfaces and Dependencies) so it can be
unit-tested and so no closure over the batch escapes into the span.

Open the span inside `withRootContext` using `consumerSpanArgsLinkedTo links`. When the link
list is empty, use the constant `consumerSpanArgs` and still use `withRootContext`: a batch span
has no member parent in any case. Add an integer attribute `shibuya.batch.links.dropped` to the
span only when the overflow counter is non-zero; define its name in
`Shibuya/Telemetry/Semantic.hs` next to the other batch attributes. Also set the spec attribute
`messaging.batch.message_count` to the number of members on every batch span, taking the key
from `OpenTelemetry.SemanticConventions` as the neighbouring definitions do, and keep
`shibuya.batch.size` unchanged for existing dashboards.

Remove the obsolete comment about the first message's context.

Add `shibuya-core/test/Shibuya/Telemetry/BatchCorrelationSpec.hs` (register it in the test
suite), using the in-memory exporter as the neighbouring telemetry specs do:

- three members with three distinct `traceparent` values: one batch span, no parent, three
  links in member order, each with `messaging.message.id` equal to its member's identifier,
  trace ID equal to none of the producers', and `messaging.batch.message_count = 3`;
- members 1 and 2 share a context, member 3 differs: three links, the first two to the same
  span with different message identifiers;
- no member has headers: no links, no parent;
- a mix with and without headers: links only for those with;
- 200 members with distinct contexts: 128 links and `shibuya.batch.links.dropped = 72`;
- after 128 valid members, append absent, malformed and valid contexts: only the valid
  remainder increments the dropped count; sparse valid contexts before the cap are retained;
- a batch where one member is superseded (ADR 0013): no link for the superseded member;
- an ambient span active around the run: the batch span is still a root and the ambient span
  is restored afterwards;
- tracing disabled: handler runs, nothing exported;
- unit tests of the pure link-collection function for the bound, ordering, and link attributes.

Update any existing batch test that asserts the batch span's parent is the first member's
producer.

### Milestone 2: performance and retention gate

Add to `shibuya-core-bench/bench/Bench/Tracing.hs` a cell
`tracing/batch1000/enabled-headers-distinct` where each of 1,000 members has a different
context (so the bound is exercised), and `tracing/batch100/enabled-headers-distinct`. The
existing `batch100` cells use one fixed header for all members and therefore now measure 100
links to one context. Do not rename existing cells.

Compare against a baseline worktree as in Concrete Steps. Reading rule:

- `batch100/disabled-*`: no slower beyond noise, no allocation increase.
- `batch100/enabled-noheaders`: no slower beyond noise; allocation unchanged apart from the
  root-context attachment and batch-count attribute, which must be explained if visible.
- `batch100/enabled-headers`: record the allocation change per batch. Compared with the
  baseline (one decode for the first member), the new code builds one link with a one-entry
  attribute map per member up to 128. Header validation continues beyond that cap; report
  its cost in the already planned large-batch cell. Report bytes per member.
- All single-message cells and all pre-existing groups: no allocation change.

If a `batch100` enabled cell fails `--fail-if-slower 10` after a confirming re-run with
`--stdev 3`, look for avoidable cost first: decoding a header identical to the previous
member's can be skipped by comparing the raw header bytes and reusing the previous decoded
context. If the cost remains,
record the numbers and take a decision in the Decision Log and the parent MasterPlan before
continuing.

Extend `shibuya-core/test-retention/Main.hs`: Check A (payloads are collected while finished
spans are still held by the in-memory exporter) for a batch of members with distinct contexts,
and Check B (live bytes flat between 20,000 and 200,000 messages) for batches with distinct
contexts. Both must pass.

### Milestone 3: documentation

In `docs/user/opentelemetry.md`, under the "Parent or link" subsection written by plan 55, add
a paragraph on batches: the batch span is a root, has one link per member up to 128, each
carrying `messaging.message.id`, reports the remainder in `shibuya.batch.links.dropped`, carries
`messaging.batch.message_count`, and is not affected by the adapter's policy. Add the two new
attributes to the attribute table in that guide. Mention that the SDK's own link limit
(`OTEL_SPAN_LINK_COUNT_LIMIT`) still applies if set lower. Update
`docs/capabilities/opentelemetry-tracing.md` and the `0.13.0.0` entry in
`shibuya-core/CHANGELOG.md` (a behaviour change: batch spans no longer join the first member's
trace). Add the batch rule and its bound to ADR 0014.

In the parent MasterPlan, mark this plan Complete and update Progress; the release gate
described there becomes actionable only once this plan, plan 55 and
`docs/plans/60-name-process-spans-and-operations-per-the-messaging-conventions.md` are Complete.


## Concrete Steps

All commands run from the repository root inside the nix devShell.

```bash
nix fmt
cabal build all
cabal test shibuya-core
cabal test shibuya-core:test:shibuya-core-test --test-options='--match "BatchCorrelation"'
```

Performance gate. `<baseline-commit>` is the final accepted commit of plan 55.

```bash
git worktree add /tmp/shibuya-tracing-baseline <baseline-commit>
( cd /tmp/shibuya-tracing-baseline && \
  cabal bench shibuya-core-bench \
    --benchmark-options="--stdev 5 --timeout 120 --csv /tmp/shibuya-tracing-baseline.csv" )
cabal bench shibuya-core-bench \
  --benchmark-options="--stdev 5 --timeout 120 --baseline /tmp/shibuya-tracing-baseline.csv --fail-if-slower 10 --csv /tmp/shibuya-tracing-after.csv"
git worktree remove /tmp/shibuya-tracing-baseline
```

Retention gate:

```bash
cabal test shibuya-core:test:shibuya-core-trace-retention-test --test-show-details=direct
```

Expected additional lines:

```text
PASS: batch/distinct-contexts: finished spans do not retain payloads
PASS: batch/distinct-contexts: live bytes flat
```


## Validation and Acceptance

Behaviour. The `BatchCorrelationSpec` cases pass. Before this plan, the three-producer case
shows a batch span parented to the first producer with zero links; after, a root span with
three links.

Bound. The 200-member case shows exactly 128 links and a dropped count of 72. Mixed-header
unit tests prove that absent/malformed overflow entries are excluded. The existing large-batch
cell reports total cost, which includes decoding all members; do not infer a storage bound from
aggregate allocation or require a new 128-member benchmark. Unit tests establish the link cap.

Performance. The benchmark comparison exits 0; disabled cells, single-message cells and
pre-existing groups show no allocation increase; the enabled batch cost per member is recorded
here with its explanation.

Space. The retention suite passes including the new batch checks.

Regression. `cabal test shibuya-core` and `cabal test shibuya-metrics` pass.


## Idempotence and Recovery

All changes are ordinary source edits recoverable with git, and every command can be repeated.
The benchmark worktree may be removed and recreated. A failing gate leaves the tree in place
for investigation; nothing is published by this plan.


## Interfaces and Dependencies

Prerequisites: plan 54 Complete; plan 55 Complete, including its M2 root-context helper.

No new package dependency. Uses `OpenTelemetry.Trace.Core` (`NewLink`, `SpanContext` with
`traceId` and `spanId`) from `hs-opentelemetry-api` `^>=1.0`.

Added to `Shibuya.Telemetry.Correlation`:

```haskell
-- | Maximum links placed on one batch span.
maxBatchLinks :: Int
maxBatchLinks = 128

-- | Result of collecting creation-context links for a batch.
data BatchLinks = BatchLinks
  { links :: ![NewLink],  -- fully evaluated, in member order, length <= maxBatchLinks
    dropped :: !Int       -- members with a creation context beyond the bound
  }

-- | Collect one link per member that has a decodable creation context, in
-- order, each carrying @messaging.message.id@. Store at most 'maxBatchLinks';
-- continue decoding to count valid omitted contexts exactly.
collectBatchLinks :: [(MessageId, Maybe TraceHeaders)] -> BatchLinks
```

The caller passes `fmap (\m -> (m.envelope.messageId, m.envelope.traceContext)) (NE.toList batch)`
or an equivalent fold that does not retain the batch; if a fold over the `NonEmpty` directly avoids building the
intermediate list, prefer it and adjust the signature, recording the change here.

Added to `Shibuya.Telemetry.Semantic`:

```haskell
attrShibuyaBatchLinksDropped :: Text
attrShibuyaBatchLinksDropped = "shibuya.batch.links.dropped"

-- | Number of messages in the batch (@messaging.batch.message_count@).
attrMessagingBatchMessageCount :: Text
attrMessagingBatchMessageCount = unkey Sem.messaging_batch_message_count
```

Confirm the generated key's name in the `hs-opentelemetry-semantic-conventions` source (locate
it with `mori registry show iand675/hs-opentelemetry --full`); if the pinned `^>=1.40` series
does not define it, use the literal `"messaging.batch.message_count"` and note that here.

No other child plan consumes these. The adapter plans (57, 58, 59 under `docs/plans/`) only
describe the resulting batch behaviour in their documentation.

Revision note (2026-11-12): exact overflow counts require full header validation; retained
links remain bounded at 128. Plan 55 Complete supplies all shared helpers. No new benchmark
cell or calibration was added by this revision.
