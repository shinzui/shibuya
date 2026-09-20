# Make WebSocket lifecycle and terminal delivery explicit

Status: Accepted

Date: 2026-09-20

## Context

The metrics WebSocket counted a connection before accepting it but installed its cleanup
only after acceptance, initial snapshot generation, and sender-thread creation. Any failure
in that gap retained the slot. Cleanup also sent `goodbye` before decrementing the count, so
a disconnected peer could make cleanup itself fail and eventually exhaust
`wsMaxConnections`. The sender thread was linked manually rather than owned structurally.

The routing layer always attempted a WebSocket upgrade even when `enableWebSocket` was
false. A connection subscribed to all processors represented that state as `Nothing`, and
selective unsubscribe from that state was acknowledged without changing the filter. Finally,
a processor that left the live metrics registry simply disappeared; a delta client retained
its last value indefinitely even though the core now preserves a bounded terminal lifecycle
snapshot.

## Decision

Own a connection slot from one masked acquisition through acceptance, snapshot generation,
the complete sender/receiver lifetime, and release. The release finalizer performs only local
STM bookkeeping. Normal peer close frames and closed transports end the connection normally;
other WebSocket exceptions continue to propagate. Run sender and receiver with structured
`race_` ownership so either side finishing cancels the other.

Represent subscriptions explicitly as either all processors with a finite exclusion set or a
finite selected set. `subscribe_all` clears exclusions, `subscribe` selects or extends the
selected set, and `unsubscribe` adds exclusions in all mode or removes selections in selected
mode. Enforce `enableWebSocket` before installing the upgrade application.

Give the shared WebSocket state a one-way shutdown signal. Active senders wait on that signal
or their next push interval in STM; shutdown wins and sends one `goodbye` before the connection
finishes. Server-thread termination always sets the signal.

Add a `terminal` server frame for a formerly visible processor whose retained lifecycle is
`stopped` or `failed`. A failure carries its error and optional message identifier. Determine
removals by comparing only the connection's last visible metrics map with the current live
registry, consult the core's retained lifecycle snapshot, and then replace that map. This
emits a terminal outcome once without creating a second, unbounded history.

## Consequences

- Failed setup, abrupt disconnect, sender failure, receiver failure, and cancellation all
  return the connection slot even if a network cleanup operation fails.
- Disabled WebSockets receive the ordinary HTTP rejection and never upgrade.
- Selective unsubscribe from subscribe-all has defined exclusion semantics.
- `ProcessorTerminalStatus` and `ServerMessage.ProcessorTerminal` are public. Adding a
  constructor to `ServerMessage`, and adding the shutdown cell to the already-public
  `WebSocketState` record, are source-breaking changes for exhaustive matches or direct record
  construction. The `terminal` JSON frame is additive on the wire.
- Cross-origin policy and alignment with a broader WebSocket convention remain outside this
  decision; the existing dialect is otherwise preserved.

## Evidence

Failing-first reproduction, real loopback protocol tests, and final validation are recorded in
[`docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`](../plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md).
The retained lifecycle contract this decision consumes is defined by
[`docs/adr/0003-make-processor-termination-and-shutdown-outcomes-explicit.md`](0003-make-processor-termination-and-shutdown-outcomes-explicit.md).
