---
type: Improvement Request
title: Expose processor progress, latency, and in-flight detail for inspection UIs
description: >-
  Extend processor metrics with a per-message processing-duration distribution, per-processor
  cursor progress where the adapter supplies one, and oldest-in-flight visibility — aggregated
  off the hot path — so an inspection UI can answer how fast a processor runs, how far it has
  gotten, and what it is stuck on.
timestamp: 2026-08-19T00:00:00Z
requestId: IR-3
status: proposed
origin: mori://shinzui/keiro-ui
---

# Improvement Request: Expose Processor Progress, Latency, and In-Flight Detail for Inspection UIs

## Status

Proposed by the keiro runtime UI initiative
(`mori://shinzui/keiro-ui/masterplans/1-keiro-runtime-ui-foundations`, filed under
`mori://shinzui/keiro-ui/plans/4-audit-shibuya-and-file-ui-endpoint-improvement-requests`). The
initiative is preparing a browser UI for applications built on the keiro runtime stack;
processor supervision views belong to shibuya per the initiative's layer-ownership matrix
(`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-1`). Implementation is shibuya's own downstream
work.

## Context

An operator watching a processor through today's surface sees `ProcessorMetrics`: state
(`Idle`/`Processing`/`Failed`/`Stopped`), received/processed/failed counters, batch statistics,
and an in-flight *count*. Three operator questions have no answer (audited 2026-08-19 at commit
`7158f3e`, re-confirmed at filing time):

- **How fast?** No per-message processing-duration distribution exists anywhere; the
  `shibuya_message_processing_seconds` metric appears only in the unimplemented design document
  `docs/plans/METRICS_WEB_UI.md`.
- **How far?** A `Cursor` rides on every `Envelope`, but the latest acknowledged cursor is
  never aggregated or exposed, so progress against a partitioned or ordered source is
  invisible.
- **On what is it stuck?** `InFlightInfo` is a count; when a processor sits in `Processing`
  for a long time, nothing says how old the oldest in-flight message is, let alone which
  message it is.

A hard constraint shapes any implementation: the metrics write path is a deliberate hot/cold
split — lock-free `AtomicCounter`s on the message path, a cold `TVar` for the rest — built
after allocation-focused performance work (shibuya plans 26, 30, and 31). This request asks for
nothing that adds per-message allocation or lock contention on the hot path; aggregation
belongs on the read side, and designs that trade a little read-side cost for zero hot-path cost
are exactly right. If individual in-flight message identity cannot meet that bar, oldest-age
alone satisfies this request.

## Requested Change

1. A per-message processing-duration distribution per processor — histogram or summary,
   whatever shibuya prefers — adequate for a latency panel (percentile or bucket rendering),
   exposed in JSON metrics, Prometheus text, and the WebSocket `update` frame additively.
2. Per-processor progress: the latest acknowledged `Cursor` (per partition, where the adapter
   supplies partitioned cursors), exposed as an opaque progress field — the UI never does
   arithmetic on cursor values, it only displays and compares them for change.
3. In-flight visibility: at minimum, the age of the oldest in-flight message per processor;
   individual message identity only if it can be had without violating the hot-path
   constraint.
4. All additions are additive to the published wire shapes: new fields in existing JSON
   objects and frames, no renames, removals, or re-typings, per the cross-project wire-stability
   convention (project `mori://shinzui/keiro-ui`, path
   `docs/architecture/inspection-api-conventions.md`, artifact-level URI pending; new fields
   snake_case).

## Acceptance

1. `GET /metrics/<processorId>` includes a processing-duration distribution once the processor
   has handled at least one message, and the same data appears in the Prometheus text
   exposition.
2. When the adapter supplies cursors, the same endpoint carries a progress field that changes
   as messages are acknowledged; when it does not, the field is absent rather than fabricated.
3. While a handler is deliberately blocked in a test, the processor's metrics report a growing
   oldest-in-flight age; after acknowledgement it clears.
4. The WebSocket `update` frame carries the same additions, and a client written against the
   pre-existing frame shape continues to work unchanged.
5. A benchmark or allocation test demonstrates the hot path gained no per-message allocation
   or shared-lock contention relative to the current baseline.

## Requested Deliverables

The metric extensions in `shibuya-core` (`Shibuya.Core.Metrics`) and their exposure through
`shibuya-metrics` (JSON, Prometheus, WebSocket), tests for each acceptance criterion, and
documentation of the new fields. Any durable design decision made along the way (for example,
the chosen aggregation strategy and its hot-path justification) should be recorded durably in
the repository — shibuya has no ADR corpus today, so the implementer should record it wherever
shibuya chooses to keep such decisions.
