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
context of every member, up to a fixed bound. From any producer's trace, a backend that follows
links can reach the batch that processed its message. This is what the OpenTelemetry messaging
conventions prescribe for batches, since a span can have only one parent.

Someone can see it working in the test suite: a batch built from messages with three distinct
`traceparent` headers yields one batch span with no parent and three links. The change must not
slow down or leak: the link list is bounded regardless of batch size, built strictly, and holds
no reference to the messages.


## Progress

- [ ] M1: Batch spans are roots linking each member's creation context, bounded and
  de-duplicated as specified; `shibuya-core/test/Shibuya/Telemetry/BatchCorrelationSpec.hs`
  passes along with the rest of `cabal test shibuya-core`.
- [ ] M2: Performance and retention gate passed against the baseline commit for the
  `tracing/batch100/*` cells and a new large-batch cell; retention suite covers batch links.
- [ ] M3: User guide, capability document, changelog and the correlation ADR describe batch
  behaviour; parent MasterPlan updated.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Batch spans take no parent from any member and this is not configurable.
  Rationale: Any single parent misattributes the batch. The adapter's `TraceCorrelation` policy
  governs single-message processing only.
  Date: 2026-11-11

- Decision: At most 128 links per batch span; further distinct contexts are counted in a span
  attribute rather than linked.
  Rationale: 128 is the OpenTelemetry SDK's default link limit per span. Bounding the list
  ourselves keeps memory per span constant for any batch size and avoids relying on the SDK's
  dropped-item handling.
  Date: 2026-11-11

- Decision: Consecutive members with the same creation context produce one link.
  Rationale: A producer that publishes many messages inside one span is common; adjacent
  comparison removes that duplication with no extra allocation. Full de-duplication would need
  a set per batch and is not worth its cost.
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
- Milestone 1 of
  `docs/plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md`
  accepted: it provides the module `Shibuya.Telemetry.Correlation` with
  `creationLink :: TraceHeaders -> Maybe NewLink` (decodes W3C trace headers into a link holding
  a fully evaluated span identity) and
  `consumerSpanArgsLinkedTo :: [NewLink] -> SpanArguments` (Consumer-kind span arguments
  carrying links).

If `shibuya-core/src/Shibuya/Telemetry/Correlation.hs` is missing, stop. Preferably plan 55 is
fully Complete before this one starts, so this plan's benchmark baseline is plan 55's last
commit and measures only the batch change.

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
`isTracingEnabled` reports the mode. If plan 55 is Complete, that module also has
`withRootContext`, which runs an action with an empty OpenTelemetry context so a span opened
inside is a root; if it is not there yet, add it as plan 55 specifies (same bracket as
`withExtractedContext`'s `Just` branch, attaching `OpenTelemetry.Context.empty`).

Batch span attributes such as `shibuya.batch.size` are named in
`shibuya-core/src/Shibuya/Telemetry/Semantic.hs`.

Relevant ADRs.
[ADR 0013](../adr/0013-let-adapters-supersede-a-delivery-before-its-handler-runs.md): superseded
members are removed before the batch span is opened; links must be computed from the surviving
members only, which is what `processCurrentBatchWithDetail` receives.
[ADR 0012](../adr/0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md):
the framework owns the processing span; disabled tracing does no per-message work.
[ADR 0006](../adr/0006-benchmark-gate-runtime-dependency-changes-regardless-of-release-level.md):
an allocation increase is a regression even when time is within noise.
Plan 55 creates a correlation ADR (the next number after 0013 in `docs/adr/`); this plan adds
the batch rule to it rather than creating another.

The performance and retention contract from the parent MasterPlan, as it applies here:

1. With tracing disabled, no header is decoded and no list is built; the batch path is as it
   was.
2. With tracing enabled, the cost added per batch is bounded by a constant (at most 128 links),
   whatever the batch size.
3. The link list is fully evaluated before the span is created and holds only evaluated span
   identities, never an `Ingested`, `Envelope`, payload, or the batch `NonEmpty`.
4. Heap residency under sustained batch processing stays flat.


## Plan of Work

### Milestone 1: fan-in links

In `processCurrentBatchWithDetail`, replace the first-member parent with a link list.

Check `isTracingEnabled` first. When disabled, call the existing body through `withSpan'` with
the constant `consumerSpanArgs` and do not traverse the batch for headers.

When enabled, make one strict left-to-right pass over the batch that accumulates, with strict
accumulators: the links collected so far (in reverse, reversed once at the end), their count,
the identity of the most recently linked context, and a count of contexts not linked because the
bound was reached. For each member, call `creationLink` on its `traceContext`; skip members
without a decodable context; skip a context whose trace ID and span ID equal the previous
linked one; if the count has reached 128, increment the overflow counter instead of consing.
Evaluate each link before it enters the list. Put this in a small pure, top-level function in
`Shibuya.Telemetry.Correlation` (signature in Interfaces and Dependencies) so it can be
unit-tested and so no closure over the batch escapes into the span.

Open the span inside `withRootContext` using `consumerSpanArgsLinkedTo links`. When the link
list is empty, use the constant `consumerSpanArgs` and still use `withRootContext`: a batch span
has no member parent in any case. Add an integer attribute `shibuya.batch.links.dropped` to the
span only when the overflow counter is non-zero; define its name in
`Shibuya/Telemetry/Semantic.hs` next to the other batch attributes.

Remove the obsolete comment about the first message's context.

Add `shibuya-core/test/Shibuya/Telemetry/BatchCorrelationSpec.hs` (register it in the test
suite), using the in-memory exporter as the neighbouring telemetry specs do:

- three members with three distinct `traceparent` values: one batch span, no parent, three
  links in member order, trace ID equal to none of the producers';
- members 1 and 2 share a context, member 3 differs: two links;
- no member has headers: no links, no parent;
- a mix with and without headers: links only for those with;
- 200 members with distinct contexts: 128 links and `shibuya.batch.links.dropped = 72`;
- a batch where one member is superseded (ADR 0013): no link for the superseded member;
- an ambient span active around the run: the batch span is still a root and the ambient span
  is restored afterwards;
- tracing disabled: handler runs, nothing exported;
- unit tests of the pure link-collection function for the bound and adjacent de-duplication.

Update any existing batch test that asserts the batch span's parent is the first member's
producer.

### Milestone 2: performance and retention gate

Add to `shibuya-core-bench/bench/Bench/Tracing.hs` a cell
`tracing/batch1000/enabled-headers-distinct` where each of 1,000 members has a different
context (so the bound is exercised), and `tracing/batch100/enabled-headers-distinct`. The
existing `batch100` cells use one fixed header for all members and therefore now measure the
de-duplicated case of a single link. Do not rename existing cells.

Compare against a baseline worktree as in Concrete Steps. Reading rule:

- `batch100/disabled-*`: no slower beyond noise, no allocation increase.
- `batch100/enabled-noheaders`: no slower beyond noise; allocation unchanged apart from the
  root-context attachment, which should be explained if visible.
- `batch100/enabled-headers`: record the allocation change per batch. Compared with the
  baseline (one decode for the first member), the new code decodes every member's header; this
  cost is linear in batch size and expected. Report bytes per member.
- All single-message cells and all pre-existing groups: no allocation change.

If a `batch100` enabled cell fails `--fail-if-slower 10` after a confirming re-run with
`--stdev 3`, look for avoidable cost first: decoding a header identical to the previous
member's can be skipped by comparing the raw header bytes before decoding. If the cost remains,
record the numbers and take a decision in the Decision Log and the parent MasterPlan before
continuing.

Extend `shibuya-core/test-retention/Main.hs`: Check A (payloads are collected while finished
spans are still held by the in-memory exporter) for a batch of members with distinct contexts,
and Check B (live bytes flat between 20,000 and 200,000 messages) for batches with distinct
contexts. Both must pass.

### Milestone 3: documentation

In `docs/user/opentelemetry.md`, under the "Parent or link" subsection written by plan 55, add
a paragraph on batches: the batch span is a root, links each member's producer up to 128,
collapses adjacent duplicates, reports the remainder in `shibuya.batch.links.dropped`, and is
not affected by the adapter's policy. Mention that the SDK's own link limit
(`OTEL_SPAN_LINK_COUNT_LIMIT`) still applies if set lower. Update
`docs/capabilities/opentelemetry-tracing.md` and the `0.13.0.0` entry in
`shibuya-core/CHANGELOG.md` (a behaviour change: batch spans no longer join the first member's
trace). Add the batch rule and its bound to the correlation ADR created by plan 55.

In the parent MasterPlan, mark this plan Complete and update Progress; the release gate
described there becomes actionable once this plan and plan 55 are both Complete.


## Concrete Steps

All commands run from the repository root inside the nix devShell.

```bash
nix fmt
cabal build all
cabal test shibuya-core
cabal test shibuya-core:test:shibuya-core-test --test-options='--match "BatchCorrelation"'
```

Performance gate. `<baseline-commit>` is the last commit of plan 55 if it is Complete,
otherwise the commit that accepted its Milestone 1.

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

Bound. The 200-member case shows exactly 128 links and a dropped count of 72, and the
`batch1000` benchmark cell's allocation per batch is not materially larger than ten times the
`batch100` distinct cell minus the unlinked members' share, demonstrating the list does not grow
past the bound.

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

Prerequisites: plan 54 Complete; plan 55 Milestone 1 accepted (plan 55 Complete preferred).

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
    dropped :: !Int       -- distinct-adjacent contexts beyond the bound
  }

-- | Collect links from members' trace headers in order, skipping members
-- without a decodable context, collapsing a context equal to the previously
-- linked one, and stopping at 'maxBatchLinks'.
collectBatchLinks :: [Maybe TraceHeaders] -> BatchLinks
```

The caller passes `fmap (\m -> m.envelope.traceContext) (NE.toList batch)` or an equivalent
fold that does not retain the batch; if a fold over the `NonEmpty` directly avoids building the
intermediate list, prefer it and adjust the signature, recording the change here.

Added to `Shibuya.Telemetry.Semantic`:

```haskell
attrShibuyaBatchLinksDropped :: Text
attrShibuyaBatchLinksDropped = "shibuya.batch.links.dropped"
```

No other child plan consumes these. The adapter plans (57, 58, 59 under `docs/plans/`) only
describe the resulting batch behaviour in their documentation.
