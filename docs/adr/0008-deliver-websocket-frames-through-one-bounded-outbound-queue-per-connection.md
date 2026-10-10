# Deliver WebSocket frames through one bounded outbound queue per connection

Status: Accepted

Date: 2026-10-10

## Context

The metrics receive loop and push loop previously wrote application frames independently.
The transport serialized bytes, but an old delta could follow a newer subscription snapshot.
A stalled write also stopped that connection's sampling. Queue bounds must cover required
frames as well as deltas: invalid-message floods and oversized snapshots are finite-resource
problems even when no updates are droppable.

## Decision

Own receive, independent sample/enqueue, and sole application writer loops structurally.
The writer sends application data and close frames; the WebSocket library retains protocol
ping handling. A producer lock serializes subscriptions, sampling, comparison ledgers and
admission, and is never held across socket IO. Subscription changes advance a generation,
remove unsent old updates and enqueue a required snapshot, including unsubscribe changes.
An already-popped update can precede that snapshot but cannot follow it.

Use a pure queue policy with strict encoded payloads and frame and byte budgets. Defaults
are 64 frames and 1 MiB; the frame budget must be at least two. Snapshots, terminal events,
errors and goodbye are required. Updates and pongs may be evicted oldest-first; only loss of
metrics updates invalidates the comparison ledger. The writer holds at most one popped frame
in addition to the bounded queue. These limits bound retained encoded queue payloads, not the
whole process heap or transient encoding of one batch.

After delta loss, stop ordinary deltas until the next sample admits terminal removals and an
adjacent `queue_overflow` error/snapshot recovery pair atomically. Required frames retain their
order. Advance terminal and snapshot ledgers only after admission, so a live connection does
not repeat admitted terminal events. Required saturation or an oversized required payload
requests close 1013 rather than exceeding bounds. No network delivery guarantee is possible
for a stalled or disconnected peer; reconnect and read a current snapshot.

Keep one close control signal outside the data queue. Subscription-limit refusal queues its
error before close 1008. Shutdown requests goodbye after earlier required frames and stops
admission. Each send and the entire close flush have the `wsSendTimeoutUs` deadline (five
seconds by default). Expiry cancels and joins the connection loops and releases its slot.
The built-in server requests and waits for bounded WebSocket shutdown before cancelling Warp;
Warp's own final wait is disabled to prevent it extending this bound indefinitely.

## Consequences

- `ServerError` is an additive wire frame and a source-breaking exported sum constructor.
  Closed decoders must handle the new tag; extension-tolerant consumers may ignore it.
- Direct `MetricsServerConfig` construction supplies the three new queue/deadline fields.
  Direct `MetricsServer` construction supplies the new `serverShutdown` action.
- Responsive shutdown peers receive goodbye. Policy/capacity closes and send timeouts do
  not promise goodbye; this is an explicit shared-convention deviation.
- Pongs are expendable under pressure; ping flooding cannot grow an unbounded required queue
  or reset the independent producer interval.
- `Shibuya.Metrics.Outbound` exposes the admission model. Optional `WebSocketHooks` support
  deterministic writer stalls, explicit producer ticks and admission observation in tests.
- Metrics remain current state, not replayable history. HTTP reads remain authoritative.

## Evidence

[EP-48](../plans/48-align-the-metrics-websocket-protocol-with-bounded-delivery-and-in-band-errors.md),
the [protocol mapping](../architecture/METRICS.md#websocket-protocol-and-conformance),
[queue model tests](../../shibuya-metrics/test/Shibuya/Metrics/OutboundQueueSpec.hs), and
[controlled loopback tests](../../shibuya-metrics/test/Shibuya/Metrics/WebSocketSpec.hs).
