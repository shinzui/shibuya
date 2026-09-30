---
id: 48
slug: align-the-metrics-websocket-protocol-with-bounded-delivery-and-in-band-errors
title: "Align the metrics WebSocket protocol with bounded delivery and in-band errors"
kind: exec-plan
created_at: 2026-09-30T23:27:06Z
intention: "intention_01m3ta8zgtebmaz00g0snjzy5a"
master_plan: "docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-09-30T23:27:06Z
---


# Align the metrics WebSocket protocol with bounded delivery and in-band errors

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture


A browser page that watches Shibuya processors over the `/ws` WebSocket endpoint of
`shibuya-metrics` today has no way to learn that something went wrong on its connection. A
malformed client frame is dropped in silence, a subscription that exceeds the retained limit
is answered only by a close code, and a slow page that stops reading for a while simply stalls
the server's push loop behind the socket's TCP window, which also delays the `goodbye` and
`terminal` frames that the page most needs to see. Two server threads write to the same
socket, so a `snapshot` answering a subscribe can be followed by an `update` that was computed
before it.

After this plan, every WebSocket connection has exactly one writer feeding it from one bounded
queue, faults on the connection arrive as an `error` frame the page can read, and a page that
falls behind is told in-band that it missed frames and is then given a fresh `snapshot`. A
client written against the 0.10.0.0 dialect keeps working unchanged: the only visible
differences are a new optional frame type and a new configuration field. The plan closes
`docs/improvement-requests/harden-shibuya-metrics-for-browser-clients-cors-tests-and-ws-convention-alignment.md`
(IR-5) by delivering its third item, the additive convention alignment with a published
conformance mapping, once the cross-origin plan
`docs/plans/47-add-configurable-cross-origin-access-to-the-metrics-server.md` has landed.

To see it working after implementation, start any application with the metrics server and
connect with a WebSocket client from the repository shell:

```bash
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
cabal run shibuya-example
```

Then, from another shell, send an invalid frame and observe the reply:

```bash
printf '{"type":"bogus"}\n' | websocat ws://127.0.0.1:9090/ws
```

```text
{"type":"snapshot","metrics":{...}}
{"type":"error","code":"invalid_message","message":"Unknown message type: bogus"}
```

The connection stays open, and a later `{"type":"ping"}` is still answered with
`{"type":"pong"}`.


## Progress


- [ ] Milestone 1: Add the `ServerError` constructor and `error` frame, emit it for invalid client frames and for subscription-limit closes, with round-trip and loopback tests seen failing first.
- [ ] Milestone 2: Add `wsMaxQueuedFrames`, the pure `Shibuya.Metrics.Outbound` policy, and the single `outputLoop` writer with drop-oldest overflow, in-band `queue_overflow`, and resync, with policy, ordering, goodbye, terminal, and overflow tests.
- [ ] Milestone 3: Publish the conformance mapping in `docs/architecture/METRICS.md`, update the package Haddock, CAP-10, changelogs, and ADRs, record wire-load sanity numbers, and close IR-5 after EP-47 is Complete.


## Surprises & Discoveries


(None yet.)


## Decision Log


- Decision: Emit `error` frames for the two faults that exist today (invalid client frames and
  subscription-limit closes) before restructuring delivery, as a separate milestone.
  Rationale: The frame is a small additive wire change whose tests are simple; landing it
  first gives Milestone 2 a frame type to use for overflow and keeps the suite green at every
  commit.
  Date: 2026-09-30

- Decision: Replace direct socket writes with one bounded outbound queue and one writer thread
  per connection, rather than documenting overflow as not applicable.
  Rationale: Today the receive loop and the push loop both call `WS.sendTextData` on the same
  connection. The `websockets` library serialises the byte writes with a lock, so frames are
  not corrupted, but their order is whichever thread ran first, so a stale `update` can follow
  a fresh `snapshot`. A single writer with a queue fixes that ordering, stops a slow peer from
  delaying `goodbye` and `terminal`, and makes the overflow signal of the cross-project
  convention honest instead of vacuous. This is the MasterPlan's recorded choice.
  Date: 2026-09-30

- Decision: Classify frames as droppable (`snapshot` answering a subscribe, `update`, `pong`)
  or retained (`terminal`, `error`, `goodbye`, and the resync `snapshot`), and never drop a
  retained frame.
  Rationale: An `update` carries the whole current metrics of a processor, so a later one
  supersedes a dropped one and the resync snapshot restores anything missed; `terminal` is a
  once-only event derived from a ledger that is advanced when the frame is queued, so dropping
  it would lose it forever. Retained frames are finite per connection, so the bound is
  exceeded only by that finite amount.
  Date: 2026-09-30

- Decision: Signal overflow with `error` code `queue_overflow` followed by a full `snapshot` for
  the current subscription, and reset the delta ledger to that snapshot.
  Rationale: The convention asks that a client that missed frames be told to re-read. Sending
  the snapshot ourselves means a browser client needs no extra request and the server's delta
  ledger cannot diverge from what the client has seen.
  Date: 2026-09-30

- Decision: Keep camelCase member names and the `error` plus `code` shape as ADR-0007 requires,
  and record the request's snake_case and nested-envelope asks as documented deviations in the
  conformance mapping.
  Rationale: The binding contract for this repository is
  `docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`;
  the frame's own members are single words (`type`, `code`, `message`) so no casing conflict
  arises in this plan, but the mapping must state the rule for later additions.
  Date: 2026-09-30


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


The metrics package lives under `shibuya-metrics/`. Its WebSocket endpoint is implemented in
`shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs`, its frame types in
`shibuya-metrics/src/Shibuya/Metrics/Types.hs`, its configuration record in
`shibuya-metrics/src/Shibuya/Metrics/Config.hs`, and the routing that installs the upgrade
handler in `shibuya-metrics/src/Shibuya/Metrics/Server.hs`. The test suite
`shibuya-metrics-test` (`shibuya-metrics/test/`) already covers every frame and route; its
loopback fixtures in `shibuya-metrics/test/Shibuya/Metrics/WebSocketSpec.hs` start the
combined WAI application on a free port with `Warp.testWithApplication` and connect with
`Network.WebSockets.runClient`.

A *frame* is one WebSocket text message; on this endpoint every frame is a JSON object with a
`type` member naming its kind. A *delta* is an `update` frame sent only when a processor's
sampled metrics differ from what the connection last sent, so the stream is
*coalescing*: two changes between pushes produce one frame carrying the newest values, never
two. *Drop-oldest* is the overflow policy that removes the earliest queued droppable frame to
make room for a new one. A *resync* is the server voluntarily sending a full `snapshot` so the
client can discard whatever partial view it holds. A *conformance mapping* is a table that
lists each element of an external convention beside how this surface satisfies it, closes it
additively, or deliberately deviates.

As of 2026-09-30 the code behaves as follows, read from source. `Types.hs` defines
`ClientMessage` (`SubscribeAll`, `Subscribe [ProcessorId]`, `Unsubscribe [ProcessorId]`,
`Ping`; tags `subscribe_all`, `subscribe`, `unsubscribe`, `ping`) and `ServerMessage`
(`MetricsSnapshot MetricsMap` as `snapshot`, `ProcessorUpdate ProcessorId ProcessorMetrics`
as `update`, `Pong`, `ProcessorTerminal ProcessorId ProcessorTerminalStatus` as `terminal`,
and `Goodbye`), each with hand-written `ToJSON` and `FromJSON` instances whose unknown-tag
branch fails with `Unknown message type: <tag>`. `WebSocket.hs` acquires a connection slot
under `mask` in `websocketApp`, rejects with `Too many connections` or `Server shutting
down`, and releases the slot in a `finally` whose action is only STM bookkeeping.
`serveConnection` calls `WS.acceptRequest`, wraps the rest in `WS.withPingThread conn 30`,
creates a `ConnectionState` (a `TVar Subscription` and a `TVar MetricsMap` named
`lastMetrics`), sends the initial `snapshot` directly with `WS.sendTextData`, and then runs
`race_ (receiveLoop ...) (pushLoop ...)`. `receiveLoop` calls `WS.receiveData`, and when
`decode` returns `Nothing` it does `pure ()`, so an undecodable frame or an unknown tag is
silently ignored. `handleClientMessage` answers `SubscribeAll` and `Subscribe` by sending a
`snapshot` directly and writing `lastMetrics`, answers `Ping` with a direct `Pong`, and on a
`Subscribe` or `Unsubscribe` that would exceed `wsMaxSubscriptions` calls
`rejectOversizedSubscription`, which sends close code 1008 with a reason text and nothing
else. `pushLoop` waits in `waitForPushOrShutdown` on either `shutdownRequested` or a
`registerDelay` of `wsPushIntervalUs`; on shutdown it sends `Goodbye` directly and returns,
otherwise it calls `pushUpdates`, which samples all metrics and the lifecycle snapshot, sends
an `update` per changed subscribed processor through `sendIfChanged`, sends one `terminal`
per processor that was in `lastMetrics` and is no longer live, and finally overwrites
`lastMetrics`. The `Subscription` type is `AllProcessors excluded` or
`SelectedProcessors selected`. Nothing is queued anywhere: every send goes straight to the
socket from whichever thread produced it.

Two library facts matter. In `websockets` 0.13.0.0, whose source was checked in the cached
source distribution for this plan, `Network.WebSockets.Stream` guards each write with an
`MVar`, so concurrent `sendTextData` calls from two threads produce intact frames in an
unspecified order; and `sendTextData` blocks once the peer stops reading and the kernel
buffers fill, so a stalled client stalls whichever thread is sending. In `stm` 2.5.3.1,
`registerDelay` (re-exported from `Control.Concurrent.STM.TVar`), `check`, `orElse`, and
`modifyTVar'` are the primitives the existing loop uses and this plan keeps using.

Three local ADRs govern this work. `docs/adr/0007-evolve-the-metrics-wire-contract-additively-and-keep-browser-access-and-control-opt-in.md`
is the binding wire contract: published frames are frozen, additions are new frame types or
optional members, member names are camelCase, tags and error codes are snake_case, and error
bodies carry a stable `code`. `docs/adr/0004-make-websocket-lifecycle-and-terminal-delivery-explicit.md`
records the slot ownership, the explicit subscription representation, the STM shutdown signal
that yields one `goodbye`, and the once-only `terminal` delivery derived from comparing the
connection's last visible map with the live registry; this plan preserves every one of those
guarantees and supersedes only the paragraph that says sender loops send `goodbye` directly.
`docs/adr/0001-remove-obsolete-linked-actors-and-test-gc-liveness.md` sets the rule that a
test for a defect must be observed failing against the unfixed code before it is trusted;
Milestones 1 and 2 follow it with isolated worktrees.

The request being closed, IR-5, cites an external convention as context: project
`mori://shinzui/keiro-ui`, path `docs/architecture/inspection-api-conventions.md`
(artifact-level URI pending), and the decision
`mori://shinzui/keiro-ui/okf/adrs/concepts/ADR-2`. That convention asks for type-tagged
frames, explicit subscribe and unsubscribe, snapshot then delta, ping and pong, in-band
`error` frames with bounded drop-oldest queues and overflow signalling, `goodbye` before a
server-initiated close, and replay cursors where a domain has them. It binds nothing in this
repository; Milestone 3 maps it against what Shibuya ships so a reader of either project can
see the fit. IR-5's first item, cross-origin access, is delivered by EP-47, and its second
item, the test suite, was delivered by
`docs/plans/39-make-metrics-health-and-websocket-lifecycle-reporting-trustworthy.md`.

The parent MasterPlan is
`docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md`. Its
Integration Points assign this plan the `ServerError` constructor, the `wsMaxQueuedFrames`
field, and the restructure of `WebSocket.hs`, and note that
`docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md`
makes `sendIfChanged` ignore a derived `ageSeconds` member; whichever of the two plans lands
second must rebase and keep that projection inside the new `outputLoop` delta computation.


## Plan of Work


### Milestone 1: the `error` frame for existing faults


Goal: a client learns about a malformed frame or an oversized subscription from the stream
itself. Work: in `shibuya-metrics/src/Shibuya/Metrics/Types.hs` add the constructor
`ServerError !Text !Text` to `ServerMessage`, where the first field is the stable snake_case
code and the second the human-readable message; extend `ToJSON` to produce
`object ["type" .= "error", "code" .= code, "message" .= message]` and `FromJSON` with an
`"error"` branch that reads both members. In `WebSocket.hs`, change `receiveLoop` so that a
`Nothing` from `decode` sends `ServerError "invalid_message" reason` where `reason` is the
parser's message obtained by switching from `decode` to `eitherDecode` (the existing
instances already produce `Unknown message type: <tag>` for an unknown tag, and Aeson
produces a syntax description otherwise), and keep looping so the connection stays open. In
`rejectOversizedSubscription`, send `ServerError "subscription_limit_exceeded" text` before the
existing `WS.sendCloseCode conn 1008 text`, with the same text as today. Do not touch any
other send in this milestone.

Result: `TypesSpec` has a `messageCase (ServerError "invalid_message" "boom")` round trip
against `object ["type" .= "error", "code" .= "invalid_message", "message" .= "boom"]`, and
`WebSocketSpec` has two new cases: a client that sends `{"type":"bogus"}` receives an `error`
frame with code `invalid_message` and then still gets `pong` for a `ping`; and a client whose
`subscribe` exceeds `wsMaxSubscriptions = 2` receives an `error` frame with code
`subscription_limit_exceeded` before the connection closes with code 1008 (read the frame,
then assert that the next `receiveData` throws `CloseRequest 1008 _`). Proof: both loopback
tests are written first, run in a detached worktree at the pre-change commit, and observed
failing (the first times out waiting for a frame, the second sees `CloseRequest` where a frame
was expected); the transcript is recorded in Surprises & Discoveries. Record in the Decision
Log and both changelogs that `error` is an additive wire frame and that adding a constructor
to the exported `ServerMessage` breaks exhaustive matches downstream.


### Milestone 2: one bounded outbound queue per connection


Goal: exactly one thread writes to each socket, frames leave in ledger order, a slow client
cannot stall `goodbye` or `terminal`, and overflow is signalled in-band followed by a resync.

Work, configuration: add `wsMaxQueuedFrames :: !Int` to `MetricsServerConfig` in `Config.hs`
with Haddock "Maximum queued outbound frames per WebSocket connection before the oldest
droppable frame is discarded (default: 64)", default 64 in `defaultConfig`, and a
`validateConfig` guard in `Server.hs` (`MetricsServerConfig.wsMaxQueuedFrames must be
positive`), following the pattern of the existing `wsMaxSubscriptions` guard. Add the field to
every direct record construction in tests and in `shibuya-metrics/bench/WireLoad.hs` if any
exist (today they all use `defaultConfig { ... }`, so expect no change).

Work, the pure policy: create `shibuya-metrics/src/Shibuya/Metrics/Outbound.hs`, listed under
`exposed-modules` in `shibuya-metrics/shibuya-metrics.cabal`, containing

```haskell
-- | One encoded frame waiting to be written to a connection.
data QueuedFrame = QueuedFrame
  { payload :: !LBS.ByteString,
    -- | Retained frames are never discarded by overflow.
    retained :: !Bool
  }
  deriving stock (Eq, Show)

-- | Append a frame to a bounded queue. Returns the new queue and whether a
-- frame was discarded. A retained frame is always appended. A droppable frame
-- is appended when the queue holds fewer than the bound; otherwise the oldest
-- droppable frame is removed first, or the new frame itself is discarded when
-- no droppable frame is queued.
enqueueBounded :: Int -> QueuedFrame -> Seq QueuedFrame -> (Seq QueuedFrame, Bool)
```

with `Data.Sequence` from `containers`, which the package already depends on. Retained
frames are `terminal`, `error`, `goodbye`, and the resync `snapshot`; droppable frames are a
`snapshot` answering a subscribe, `update`, and `pong`. State the invariant in the module
header: the queue length exceeds the bound only by retained frames, and retained frames are
finite per connection (one `goodbye`, at most one `error` per fault, at most one `terminal`
per processor ever removed).

Work, the connection state: in `WebSocket.hs` extend `ConnectionState` with
`outbound :: !(TVar (Seq QueuedFrame))`, `overflowed :: !(TVar Bool)`, and
`sendLock :: !(MVar ())`, all created in `newConnectionState`. Add an internal
`enqueueFrame :: Int -> ConnectionState -> Bool -> ServerMessage -> IO ()` that encodes the
message, runs `enqueueBounded` inside `modifyTVar'`-style STM on `outbound`, and sets
`overflowed` to `True` when a drop is reported. Every place that calls `WS.sendTextData`
today becomes a call to `enqueueFrame`, except the writer itself.

Work, the writer: replace `pushLoop` and `waitForPushOrShutdown` with
`outputLoop :: MetricsServerConfig -> Master -> WebSocketState -> ConnectionState ->
WS.Connection -> IO ()`. Each iteration creates a `registerDelay` for `wsPushIntervalUs` and
waits in one STM transaction, using `orElse`, for the first of three events: `shutdownRequested`
is `True`; `outbound` is non-empty, in which case the transaction pops the head frame and
returns it; or the delay elapsed. A popped frame is written with `WS.sendTextData conn
frame.payload`; this is the only `sendTextData` call left in the module. On the interval tick
the loop first checks `overflowed`: if set, it takes `sendLock`, enqueues a retained
`ServerError "queue_overflow" "Frames were discarded because this connection fell behind; a
fresh snapshot follows"`, samples the current metrics, filters them by the current
subscription, enqueues that `snapshot` as retained, writes `lastMetrics` to it, clears
`overflowed`, and releases the lock; otherwise it runs the existing `pushUpdates` logic under
`sendLock`, enqueuing each changed `update` as droppable and each `terminal` as retained and
then writing `lastMetrics`, exactly as `pushUpdates` orders those steps today. When shutdown
wins, the loop enqueues `Goodbye` as retained, then drains: it pops and writes every remaining
frame in order until the queue is empty, and returns. Because `serveConnection` keeps
`race_ (receiveLoop ...) (outputLoop ...)`, returning ends the connection as before, and the
slot-release `finally` in `websocketApp` is unchanged. Keep `normalPeerClosure`, the initial
`snapshot` (now enqueued under `sendLock` before the race starts, with `lastMetrics` written
in the same critical section), the subscribe-all exclusion semantics, and the `terminal`
derivation untouched.

Work, the receive loop: `handleClientMessage` answers `SubscribeAll` and `Subscribe` by taking
`sendLock`, sampling and filtering the metrics, enqueuing the droppable `snapshot`, and writing
`lastMetrics`, all inside the lock, so that queue order equals ledger order and the writer's
next delta is computed against the map the client will have seen. `Ping` enqueues a droppable
`Pong`. `rejectOversizedSubscription` enqueues the retained `error` and then sends the close
code as today; the close code is sent directly because it is not a data frame and the
connection ends immediately after.

If EP-49 has already landed, its `sendIfChanged` projection that zeroes the derived
`ageSeconds` member before comparing must be carried into the delta computation unchanged;
if EP-49 lands later, it adds that projection to the new `outputLoop` code. Note which case
applied in Surprises & Discoveries.

Result and proof: a new test module `shibuya-metrics/test/Shibuya/Metrics/OutboundQueueSpec.hs`
(registered in `other-modules` and in `shibuya-metrics/test/Main.hs`) covers the pure policy:
appending below the bound; dropping the oldest droppable when full and reporting `True`;
discarding the new droppable frame when only retained frames are queued; and appending a
retained frame beyond the bound without a drop. `WebSocketSpec` gains four loopback cases.
Ordering: with processors `alpha` and `beta` registered and `fastConfig`, the client sends
`subscribe` for `alpha` while a background thread increments both processors' received
counters every millisecond; after the selective `snapshot` arrives, no later frame within
200 ms may be an `update` for `beta`. Goodbye: the existing shutdown test still receives
`goodbye`, and a variant with several queued updates receives them all before `goodbye`.
Terminal: the existing once-only terminal test still passes, and a variant with
`wsMaxQueuedFrames = 1` and continuous updates still delivers the `terminal` exactly once.
Overflow: register 512 idle processors, use push interval 1 ms and `wsMaxQueuedFrames = 4`,
connect, read the initial snapshot, then sleep 500 ms while a background thread increments
every processor's received counter continuously; on resuming reads the client must receive,
possibly after some `update` frames, an `error` frame with code `queue_overflow` immediately
followed by a `snapshot`, and afterwards a `ping` must still be answered. Run the overflow
case twenty times in a loop with `--match` and record the results; if it is not stable in
twenty of twenty runs, replace it with a deterministic test that injects a blocking send
hook (a test-only field on `WebSocketState` that wraps the writer's send, defaulting to the
real send) and record that decision in the Decision Log. Both the ordering and overflow tests
are run first in a detached worktree at the Milestone 1 commit and observed failing (the
ordering test sees a stale `beta` update; the overflow test never sees an `error` frame).


### Milestone 3: conformance mapping, records, and closure


Goal: a reader can see how the shipped protocol relates to the external convention, every
record that describes the package is current, and IR-5 is closed with evidence. Work: append
a section "WebSocket protocol and conformance" to `docs/architecture/METRICS.md` that first
describes the protocol as it now is (client frames, server frames including `error` with its
three codes `invalid_message`, `subscription_limit_exceeded`, and `queue_overflow`, the
bounded queue, the drop-oldest policy, the resync sequence, and `goodbye`) and then gives the
mapping, one row per element: type-tagged frames, met; explicit subscribe and unsubscribe,
met; snapshot then delta, met; ping and pong with a 30-second server ping, met; in-band
`error` frames, additively closed by this plan; bounded per-connection queue with overflow
signalling, additively closed by this plan; `goodbye` before a server-initiated close, met;
replay cursor `from_position`, documented deviation because metrics are current state rather
than a replayable log and a fresh `snapshot` is the recovery path; snake_case member names,
documented deviation per ADR-0007 (camelCase members, snake_case tags, values, and codes);
nested error envelope, documented deviation per ADR-0007 (`error` plus `code`); cross-origin
access, met by the `corsAllowedOrigins` configuration of EP-47 (cite its plan path and, once
landed, the `Config.hs` field); authentication, documented posture of none, with a trusted
network or an authenticating reverse proxy expected in front of the server. Update the Haddock
header of `shibuya-metrics/src/Shibuya/Metrics.hs` to list the `error` frame, its codes, the
overflow and resync behaviour, and `wsMaxQueuedFrames`. Update
`docs/capabilities/metrics-endpoints.md` (CAP-10): remove the limit sentence that says bounded
slow-consumer queues, overflow signalling, and convention alignment remain open, add
`shibuya-metrics/test/Shibuya/Metrics/OutboundQueueSpec.hs` and the new `WebSocketSpec` cases
as evidence entries, keep the authentication limit and, until EP-47 lands, the cross-origin
limit; append to `docs/capabilities/log.md` with `okf log add` and validate the bundle with
its profile. Create the ADR `docs/adr/<next unused four-digit number>-deliver-websocket-frames-through-one-bounded-outbound-queue-per-connection.md`
(EP-49, EP-51, and EP-52 also allocate ADR numbers, so take the next unused one when this
milestone runs) in
the same plain-Markdown format as ADR-0004 with Status, Date, Context, Decision, Consequences,
and Evidence, recording the single-writer rule, the droppable and retained classification,
the overflow signal and resync, and the bound; then add one line directly under the Status
line of `docs/adr/0004-make-websocket-lifecycle-and-terminal-delivery-explicit.md` reading
"Superseded in part by [the outbound-queue decision](<number>-deliver-websocket-frames-through-one-bounded-outbound-queue-per-connection.md): sender loops no longer
write to the socket directly." Add entries under an `Unreleased` heading in `CHANGELOG.md` and
`shibuya-metrics/CHANGELOG.md`: the additive `error` frame, the source-breaking `ServerMessage`
constructor, the new `wsMaxQueuedFrames` field affecting direct record construction, the
single-writer ordering guarantee, and the new exposed module. Run the wire-load fixture's
websocket-churn scenario before Milestone 2 and after Milestone 3 and record both JSON
reports' `operationsPerSecond` and `latencyP95Micros` in Surprises & Discoveries; this is a
sanity check, not a gate, because the fixture measures connection churn rather than message
throughput.

Closure: only when the registry row for EP-47 in the MasterPlan reads Complete, edit
`docs/improvement-requests/harden-shibuya-metrics-for-browser-clients-cors-tests-and-ws-convention-alignment.md`:
set `status: completed`, add `completedAt` with the UTC time of the final passing test run,
add `resolution` naming EP-39, EP-47, and this plan by path, advance `timestamp` to the same
time, and add a sentence to its Status section pointing at the conformance mapping. Append a
dated entry with `okf log add` and validate the bundle. If EP-47 is not Complete, finish every
other step, mark this plan's Progress with the closure item split into "done except IR-5
closure" and "remaining: close IR-5 after EP-47", and stop.


## Concrete Steps


All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` inside the Nix development shell.
Build and test after every edit:

```bash
cabal build all
cabal test shibuya-metrics --test-show-details=direct
cabal test shibuya-core
nix fmt
```

A successful metrics run ends with a line of the form `N examples, 0 failures` where N is
greater than the 48 examples the suite had at 0.10.0.0; a zero-example run is not a pass.

Failing-first evidence for Milestone 1 (repeat with the Milestone 1 commit for Milestone 2):

```bash
git worktree add --detach /tmp/shibuya-ep48-red HEAD
# copy only the new test cases into /tmp/shibuya-ep48-red, then:
cd /tmp/shibuya-ep48-red && cabal test shibuya-metrics --test-show-details=direct \
  --test-options='--match "error frame"'
cd /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya
git worktree remove --force /tmp/shibuya-ep48-red
```

Expected in the worktree: the invalid-frame case fails with a timeout or an unexpected
`Pong`, and the limit case fails with an uncaught `CloseRequest 1008`. Paste the failure lines
into Surprises & Discoveries.

Overflow stability run for Milestone 2:

```bash
for i in $(seq 1 20); do
  cabal test shibuya-metrics --test-show-details=direct \
    --test-options='--match "queue_overflow"' || echo "RUN $i FAILED"
done
```

Wire-load sanity numbers, before Milestone 2 and after Milestone 3:

```bash
SCENARIO=websocket ITERATIONS=500 OUTPUT_JSON=/tmp/ep48-ws-before.json \
  cabal run shibuya-metrics:metrics-wire-load
```

Capability and improvement-request bundle maintenance:

```bash
okf log add docs/capabilities --kind Update \
  -m "CAP-10: record the error frame, bounded outbound queue, and conformance mapping as WebSocket evidence."
okf validate docs/capabilities --strict --profile docs/capabilities/profile.dhall \
  --profile-enforce --log-enforce
okf log add docs/improvement-requests --kind Update \
  -m "IR-5 completed: cross-origin access (EP-47), the contract suite (EP-39), and additive WebSocket alignment with a conformance mapping (EP-48)."
okf validate docs/improvement-requests --strict \
  --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
```

The improvement-request validation prints one `missing profile-recommended field: reviews`
advisory per concept; those pre-date this plan and are expected. Any other diagnostic must
be fixed before committing.

Commit with conventional-commit messages and these trailers on every commit:

```text
MasterPlan: docs/masterplans/7-browser-ready-processor-inspection-and-control-surface.md
ExecPlan: docs/plans/48-align-the-metrics-websocket-protocol-with-bounded-delivery-and-in-band-errors.md
Intention: intention_01m3ta8zgtebmaz00g0snjzy5a
```


## Validation and Acceptance


After Milestone 1, `cabal test shibuya-metrics` passes and includes the `ServerError` round
trip and the two loopback cases; a client that sends `{"type":"bogus"}` over a real socket
receives `{"type":"error","code":"invalid_message","message":"Unknown message type: bogus"}`
and is still answered with `pong` afterwards; a client whose `subscribe` exceeds the limit
receives an `error` frame with code `subscription_limit_exceeded` and is then closed with
code 1008.

After Milestone 2, `grep -n 'sendTextData' shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs`
shows exactly one call, inside `outputLoop`; `OutboundQueueSpec` passes; a selective
`subscribe` issued while updates flow is answered by its `snapshot` with no later `update` for
an excluded processor; `goodbye` still arrives on shutdown after every queued frame; a
processor removed with a retained terminal lifecycle produces exactly one `terminal` frame
even with `wsMaxQueuedFrames = 1`; and a client that stops reading receives an `error` frame
with code `queue_overflow` followed immediately by a `snapshot` once it resumes, in twenty of
twenty runs or through the recorded deterministic replacement. Every pre-existing
`WebSocketSpec`, `TypesSpec`, `ServerSpec`, golden, and health example still passes, and the
golden fixtures are byte-for-byte unchanged, because this plan changes no metrics encoder.

After Milestone 3, `docs/architecture/METRICS.md` contains the conformance mapping with every
listed element classified; the `Shibuya.Metrics` Haddock lists the `error` frame and its
codes; `okf validate` passes for both bundles with only the pre-existing `reviews` advisories;
the outbound-queue ADR exists and ADR-0004 carries the superseded-in-part note; both changelogs list the
changes under `Unreleased`; and, when EP-47 is Complete, IR-5 reads `status: completed` with
`completedAt` and `resolution` set.

Use STM barriers or the injected hook for interleavings; a bare sleep proves nothing about
ordering. Assert on received frames and connection outcomes, not on logs. Record exact seeds,
commands, and the twenty-run overflow transcript in this plan.


## Idempotence and Recovery


Every command above can be repeated safely. Worktrees for failing-first evidence are created
with `git worktree add --detach` and removed with `git worktree remove --force`; never apply
the reverted test mutation to the main working tree. `okf log add` appends; if an entry is
added twice, delete the duplicate line by hand before validating. Editing IR-5's frontmatter
is reversible with `git checkout -- docs/improvement-requests/...`. If Milestone 2's
restructure regresses a pre-existing test, keep the single-writer design and fix the
ordering under `sendLock` rather than reintroducing a second writer; if the overflow test
proves flaky, follow the recorded fallback to the injected hook rather than loosening the
assertion. Commit each milestone separately so a partial failure is recoverable by
reverting one commit with the trailers above.


## Interfaces and Dependencies


Libraries, all already dependencies of `shibuya-metrics`: `websockets ^>=0.13` (0.13.0.0 in
the current solution) for `acceptRequest`, `receiveData`, `sendTextData`, `sendCloseCode`,
`withPingThread`, `runClient`, `runClientWith`, and the `ConnectionException` constructors
`CloseRequest` and `ConnectionClosed`, verified in the cached 0.13.0.0 source distribution;
`stm ^>=2.5` (2.5.3.1) for `TVar`, `registerDelay`, `check`, `orElse`, and `modifyTVar'`,
verified in the Mori-registered `haskell/stm` source at
`/Users/shinzui/Keikaku/hub/haskell/stm-project`; `wai-websockets ^>=3.0` (3.0.1.2) for
`websocketsOr`, verified in the Mori-registered `yesodweb/wai` source; `containers ^>=0.7`
for `Data.Sequence`; `aeson ^>=2.2` for `eitherDecode`; and `base` for `MVar`. No new
dependency is added.

Interfaces that must exist at the end of Milestone 1, in
`shibuya-metrics/src/Shibuya/Metrics/Types.hs`:

```haskell
data ServerMessage
  = MetricsSnapshot !MetricsMap
  | ProcessorUpdate !ProcessorId !ProcessorMetrics
  | Pong
  | ProcessorTerminal !ProcessorId !ProcessorTerminalStatus
  | ServerError !Text !Text -- ^ stable snake_case code, human-readable message
  | Goodbye
```

encoded as `{"type":"error","code":<code>,"message":<message>}` and decoded by the `"error"`
branch of `parseJSON`.

Interfaces at the end of Milestone 2, in `shibuya-metrics/src/Shibuya/Metrics/Config.hs`:

```haskell
wsMaxQueuedFrames :: !Int -- ^ default 64; validated positive by Shibuya.Metrics.Server
```

in the new module `shibuya-metrics/src/Shibuya/Metrics/Outbound.hs`:

```haskell
data QueuedFrame = QueuedFrame {payload :: !LBS.ByteString, retained :: !Bool}
enqueueBounded :: Int -> QueuedFrame -> Seq QueuedFrame -> (Seq QueuedFrame, Bool)
```

and in `shibuya-metrics/src/Shibuya/Metrics/WebSocket.hs`, internal but named here so the
structure is unambiguous:

```haskell
outputLoop ::
  MetricsServerConfig -> Master -> WebSocketState -> ConnectionState -> WS.Connection -> IO ()
enqueueFrame :: Int -> ConnectionState -> Bool -> ServerMessage -> IO ()
```

where `ConnectionState` gains `outbound :: !(TVar (Seq QueuedFrame))`,
`overflowed :: !(TVar Bool)`, and `sendLock :: !(MVar ())`. The exported `WebSocketState`,
`newWebSocketState`, `shutdownWebSockets`, and `websocketApp` keep their types; `combinedApp`
in `Server.hs` is unchanged.

Plan dependencies: none are hard. `docs/plans/47-add-configurable-cross-origin-access-to-the-metrics-server.md`
is a soft dependency that gates only the IR-5 closure step of Milestone 3 and the
cross-origin row of the conformance mapping. `docs/plans/49-expose-per-processor-latency-distribution-and-oldest-in-flight-detail.md`
shares `sendIfChanged`; whichever lands second rebases and keeps the derived-age projection.
This plan owns `Shibuya.Metrics.WebSocket`, `Shibuya.Metrics.Outbound`, the `ServerMessage`
sum, the `wsMaxQueuedFrames` field, the conformance section of `docs/architecture/METRICS.md`,
the outbound-queue ADR, and the closure of IR-5, and touches no `shibuya-core` module.
