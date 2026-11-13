# Define consumer correlation and bounded batch link accounting

Status: Accepted

Date: 2026-11-12

## Context

[ADR 0012](0012-keep-telemetry-ownership-and-disabled-context-contracts-explicit.md)
assigns incoming context to adapters and processing spans to the framework. MasterPlan 8
adds adapter policy and a public processing helper. Its review exposed ambiguity over absent
headers, meaningful ambient operations and exact batch overflow accounting.

## Decision

Adapters carry an extensible telemetry value; the core owns correlation and context restoration.
For single messages with usable creation headers, `ParentAndLink` uses the creation context as
parent and link; `LinkOnly` creates a new root with that link. Without usable headers, both
policies retain the existing ambient parent and emit no link. Malformed headers follow the
absent-header path. Disabled tracing performs no header decoding.

Both public helpers, `withProcessSpan` and `withProcessSpanIO`, use that contract. They serve
independent message processing: with valid creation headers they neither parent to nor link a
meaningful ambient operation. Document this limitation explicitly for direct callers. Restore
prior context on success, failure and cancellation. The effect helper also preserves the
existing disabled sentinel contract; the IO helper uses its supplied tracer.

Batch spans are roots, independent of adapter policy. Retain the first 128 valid member links
in member order, including duplicate contexts with distinct message identifiers. Decode all
remaining headers to count valid omitted contexts exactly in `shibuya.batch.links.dropped`;
absent and malformed contexts do not contribute. Do not construct link objects or attribute
maps after the cap. The bound applies to retained links, not total scan time or transient
decoding allocation. Neither links nor attributes retain message envelopes or payloads.

Kafka and PGMQ retain `ParentAndLink` by default; Kiroku chooses `LinkOnly` for replay semantics.
The [messaging conventions](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/)
allow creation-context parenting for single messages and qualify their recommendation against
that default to processing within another span. The defaults alone are not a conformance gap;
discarding a meaningful ambient relationship is a deliberate limitation.

Processing and batch spans are named `process <destination>`, the conventions'
`{messaging.operation.name} {destination}`, and carry `messaging.operation.name = process`
(EP-7). The destination in the name is the processor id even when an adapter overrides
`messaging.destination.name` per message, which keeps the name a per-processor constant.
Receive/settle spans, baggage, propagator replacement and links-aware sampling remain outside
this initiative.

## Consequences

A no-header `LinkOnly` call can have an ambient parent. The name describes how a usable
creation context is correlated, not an unconditional root guarantee. Callers requiring ambient
operation correlation must not assume these helpers supply it.

Batch accounting is linear in members plus header decoding work while retained link count is
bounded. Existing performance gates still apply; exact counts do not authorize a regression
waiver, new benchmark variants, calibration or additional setup. EP-3's root attachment and
batch attributes and EP-7's operation-name attribute have explicitly measured cost allowances.

EP-2 owns the link helpers and root-context operation. EP-3 starts after EP-2 Complete.
Publication blocks adapter implementation; PGMQ's representative check precedes Kafka/Kiroku
completion. These coordination requirements prevent divergent helper definitions and untested
cross-adapter documentation.

## Evidence

The core contract is implemented and accepted (2026-11-12): single-message correlation (EP-2),
batch linking (EP-3) and naming (EP-7). Each passed its behaviour, retention, allocation and
time gates. The adapter defaults above are adopted by the adapter plans after the
`shibuya-core` 0.13.0.0 release; until then, Kafka, PGMQ and Kiroku run on 0.12 and show
the previous behaviour.

- Interface: `Shibuya.Telemetry.Correlation` exports `TraceCorrelation`, `AdapterTelemetry`
  with its field but without its constructor, `defaultAdapterTelemetry`, `creationLink`,
  `creationLinkWith` and `consumerSpanArgsLinkedTo`. `Shibuya.Telemetry.Process` exports
  `withProcessSpan` and `withProcessSpanIO`. `Shibuya.Telemetry.Effect` exports
  `withRootContext`. `Adapter` has `telemetry :: !AdapterTelemetry`. The runner's `processOne`
  is built on `withProcessSpan`, so the runner and direct callers share one implementation of
  the rule above.
- Behaviour: `shibuya-core/test/Shibuya/Telemetry/CorrelationSpec.hs` (28 examples) covers
  parent and link under `ParentAndLink`, root and link under `LinkOnly` even with an ambient
  span, ambient parentage and no link for absent or malformed headers, `currentTraceHeaders`
  under `LinkOnly`, superseded deliveries, disabled tracing, and both helpers called directly.
- Space: `shibuya-core-trace-retention-test` passes for both policies. Finished spans held by an
  exporter do not keep payloads alive, and live bytes stay flat from 20,000 to 200,000 messages.
- Cost, against [plan 54](../plans/54-establish-tracing-enabled-performance-and-retention-baselines.md)'s
  baseline: single-message processing allocates about 208 bytes per message less on every path.
  The disabled path no longer decodes headers (`disabled-headers` equals `disabled-noheaders`).
  With headers the enabled path allocates 1,151 bytes per message more than without them,
  against 1,360 before; the link costs less than the second unlift it replaced. Time was within
  the gate on a quiet machine except one 100-message microbenchmark accepted as noise, see
  [EP-2](../plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md).
- Batches (EP-3, [plan 56](../plans/56-link-every-batch-member-s-creation-context-from-the-batch-span.md)):
  `collectBatchLinksBy` folds once over the surviving members.
  `shibuya-core/test/Shibuya/Telemetry/BatchCorrelationSpec.hs` covers member order, message-id
  link attributes, shared contexts, the 128 bound with an exact count of valid omitted
  contexts, superseded members, policy independence, ambient restoration and disabled tracing.
  Each linked member costs about 625 bytes. A 1,000-member batch with distinct contexts
  allocates less than ten 100-member batches, because it stores only 128 links. A batch without
  headers pays about 346 bytes for root attachment and the count attribute.
- Naming (EP-7, [plan 60](../plans/60-name-process-spans-and-operations-per-the-messaging-conventions.md)):
  the semantic, correlation and batch specs assert `process <destination>` and
  `messaging.operation.name = process` for single and batch spans. The attribute costs one map
  entry: 311 bytes per traced message and about 225 bytes per batch, with no measurable time.
- Time: EP-3 and EP-7 passed `--fail-if-slower 10` in two interleaved confirming runs at
  `--stdev 3`, each started below load 8. Machine load from other work made sequential runs
  unreadable; `shibuya-core-bench/README.md` records the method.
- Measurement constraint: hs-opentelemetry creates non-recording spans when a provider has no
  span processors. Enabled-path benchmarks and retention checks must use a provider with at
  least one processor.

[MasterPlan 8](../masterplans/8-configurable-trace-correlation-for-consumer-spans.md) coordinates
[EP-2](../plans/55-add-an-adapter-declared-trace-correlation-policy-to-single-message-processing.md),
[EP-3](../plans/56-link-every-batch-member-s-creation-context-from-the-batch-span.md), and
[EP-7](../plans/60-name-process-spans-and-operations-per-the-messaging-conventions.md).
