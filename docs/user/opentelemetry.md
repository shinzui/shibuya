# OpenTelemetry Tracing in Shibuya

Shibuya emits one OpenTelemetry Consumer-kind span per message and
propagates trace context end-to-end through any adapter. This guide
covers how to enable it, the two `Envelope` fields that drive it
(`traceContext` vs. `attributes`), how to add your own spans inside
handlers, and how to verify the wiring locally with Jaeger.

This guide assumes you have already read [Getting Started](./getting-started.md)
and have a `runApp`-based consumer.


## Quick start

To turn tracing on, wrap your `runApp` call in `runTracing` against a
`Tracer` you build yourself. The framework requires `Tracing :> es`
on `runApp`'s effect stack; the caller decides whether to plug in a
real tracer or a noop.

```haskell
import Control.Exception (bracket)
import OpenTelemetry.Trace (initializeGlobalTracerProvider, makeTracer,
                            shutdownTracerProvider, tracerOptions)
import Shibuya.Telemetry.Effect (runTracing)
import Shibuya.App (defaultAppConfig, runApp, waitApp)

main :: IO ()
main = bracket initializeGlobalTracerProvider shutdownTracerProvider $ \provider -> do
  let tracer = makeTracer provider "my-service" tracerOptions
  runEff . runTracing tracer $ do
    adapter <- pgmqAdapter config           -- or kafkaAdapter config
    Right appHandle <- runApp defaultAppConfig
      [ (ProcessorId "orders", QueueProcessor adapter myHandler Unordered Serial) ]
    waitApp appHandle
```

To turn tracing off without removing the wiring, swap `runTracing
tracer` for `runTracingNoop`:

```haskell
runEff . runTracingNoop $ do
  ...
```

`runTracingNoop` short-circuits every span-API call. There is no
`OTEL_SDK_DISABLED=true` knob inside Shibuya; that's for the SDK
layer (when one is present).

### Environment variables

`hs-opentelemetry-sdk` reads these on `initializeGlobalTracerProvider`:

| Variable | Purpose |
|----------|---------|
| `OTEL_SERVICE_NAME` | Service name on every span |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint (e.g. `http://localhost:4318`) |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` or `http/protobuf` |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on`, `parentbased_traceidratio`, `always_on`, `always_off`, … |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler arg (e.g. `0.1` for 10% sampling) |

A typical local development setup:

```bash
export OTEL_SERVICE_NAME="my-shibuya-consumer"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
export OTEL_TRACES_SAMPLER="always_on"
```


## What Shibuya emits per message

Inside `runApp`, the framework's `processOne` opens **exactly one
Consumer-kind span per message**, named `"<ProcessorId> process"`
per the OpenTelemetry messaging-spans spec. The span:

-   Is parented on the message's W3C `traceparent` if the queue
    carried one (otherwise it's a root span).
-   Carries the spec-aligned messaging attributes
    `messaging.system`, `messaging.destination.name`,
    `messaging.operation.type = "process"`, `messaging.message.id`, plus
    Shibuya-specific `shibuya.inflight.count`,
    `shibuya.inflight.max`, `shibuya.ack.decision`.
-   Carries any **adapter-supplied** attributes from
    `Envelope.attributes` (see below) — for the Kafka adapter that
    means typed `messaging.kafka.destination.partition` and
    `messaging.kafka.message.offset`.
-   Is marked `Ok` for `AckOk` / `AckRetry`, `Error` for
    `AckDeadLetter` / `AckHalt` / handler exceptions.
-   Records two events: `shibuya.handler.started` and either
    `shibuya.handler.completed` (success) or `shibuya.ack.decision`
    (error).

You don't write any of that code. The handler returns an
`AckDecision`; the framework owns the span.


## `Envelope.traceContext` vs. `Envelope.attributes`

These two fields are the entire OpenTelemetry-shaped surface on the
`Envelope`. They serve different purposes:

| | `traceContext :: Maybe TraceHeaders` | `attributes :: HashMap Text Attribute` |
|---|---|---|
| **What it is** | The producer's W3C trace headers (`traceparent`/`tracestate`) | OTel attributes for the per-message span |
| **Direction** | Flows **in** from the queue | Flows **out** to the trace store |
| **Used for** | Setting the **parent** of the consumer's span | **Labeling** the consumer's span |
| **When read** | *Before* the per-message span opens (sets the active context) | *After* the span opens (calls `addAttributes`) |
| **Source** | Queue-native headers (`crHeaders`, `msg.headers`) | Adapter knowledge of the broker |

Lineage and labeling are independent concerns. A message from Kafka
might carry both: a `traceparent` from whatever upstream service
produced it, plus `messaging.kafka.destination.partition=2`
labeling. A handwritten test message might have neither: a
`traceContext = Nothing` (root span) and `attributes = HashMap.empty`
(framework defaults stand).

### Concrete examples

**Kafka message, partition 2, offset 42, with upstream traceparent:**

```haskell
Envelope
  { messageId    = "orders-2-42"
  , partition    = Just "2"
  , traceContext = Just [("traceparent", "00-abc...def-01")]
  --                ^ consumer's processOne span will be a child of `def`
  , attributes   = HashMap.fromList
      [ ("messaging.system",                       toAttribute @Text "kafka")
      , ("messaging.kafka.destination.partition",  toAttribute @Int64 2)
      , ("messaging.kafka.message.offset",         toAttribute @Int64 42)
      ]
  --                ^ those typed labels appear on the span
  , ...
  }
```

**Pgmq message, no upstream trace:**

```haskell
Envelope
  { messageId    = "12345"
  , traceContext = Nothing
  --                ^ consumer's span is a root span
  , attributes   = HashMap.empty
  --                ^ framework defaults stand: messaging.system="shibuya", ...
  , ...
  }
```

### The override rule

If an adapter puts a key in `attributes` that the framework also
sets as a default (e.g. `messaging.system`), **the adapter wins**.
That's how the Kafka adapter flips `messaging.system` from
`"shibuya"` to `"kafka"`. Internally `processOne` does:

```haskell
HashMap.union envelope.attributes frameworkDefaults
--             ^ left-biased: adapter's keys override
```

The framework's `messaging.destination.name`,
`messaging.operation.type`, `messaging.message.id` derive from the
`ProcessorId` and `Envelope.messageId` — adapters should not
duplicate those keys.


## Custom spans inside your handler

The framework's per-message span is the parent of anything you open
inside the handler. Use `withSpan` (no span handle) or `withSpan'`
(span handle threaded through, useful for `addAttribute`) from
`Shibuya.Telemetry.Effect`:

```haskell
import Shibuya.Telemetry.Effect (withSpan, withSpan', addAttribute, setStatus)
import Shibuya.Telemetry.Semantic (internalSpanArgs)

myHandler :: (Tracing :> es, IOE :> es) => Handler es Order
myHandler msg = do
  let order = msg.envelope.payload

  -- Span 1: validation
  withSpan "validate-order" internalSpanArgs $ do
    validate order

  -- Span 2: persistence (with the span handle so we can label it)
  result <- withSpan' "persist-order" internalSpanArgs $ \sp -> do
    addAttribute sp "order.id"     order.orderId
    addAttribute sp "order.amount" order.amount
    persistOrder order

  case result of
    Right () -> pure AckOk
    Left e   -> pure $ AckDeadLetter (InvalidPayload (Text.pack (show e)))
```

`internalSpanArgs` produces a `SpanKind = Internal`. For an outgoing
HTTP call use `SpanKind = Client`; for a database query, `Client`
or a system-specific kind.

If you want to handle the disabled case explicitly, gate on
`isTracingEnabled` — but for simple attribute/event additions it's
cheaper to just call them; `runTracingNoop` short-circuits every
operation.


## Distributed tracing across hops

Tracing is end-to-end as long as every producer and consumer along
the chain reads and writes the W3C `traceparent` header on the
queue. **Adapters handle the consumer side automatically:** Shibuya
adapters should populate `Envelope.traceContext` from queue-native
headers when constructing envelopes.

The producer side — including DLQ writes from inside a Shibuya
handler — needs help.

### Producing messages from a handler

If your handler produces a follow-on message, attach the current
trace context so the downstream consumer's span links back to
yours. Use `currentTraceHeaders`:

```haskell
import Shibuya.Telemetry.Propagation (currentTraceHeaders)

myHandler msg = do
  ...
  outgoingHeaders <- currentTraceHeaders
  -- outgoingHeaders :: Maybe TraceHeaders
  -- (Nothing if tracing is disabled or no active span at this point;
  --  Just hdrs otherwise — attach them to the produced message.)

  produceMessage payload (fromMaybe [] outgoingHeaders)
  pure AckOk
```

`currentTraceHeaders` is in `Shibuya.Telemetry.Propagation` and
returns the active span's W3C headers. The lower-level
`injectTraceContext :: Span -> IO TraceHeaders` is also exported
for callers that already hold a `Span` handle from inside a
`withSpan'`.

### DLQ writes (pgmq)

The pgmq adapter does this for you. When your handler returns
`AckDeadLetter`, the adapter calls `currentTraceHeaders` and
injects the **failing consumer's** trace context onto the DLQ
message:

-   The consumer's `traceparent` becomes the DLQ message's active
    `traceparent`.
-   The original producer's `traceparent`/`tracestate` (if any)
    move to `x-shibuya-upstream-traceparent` /
    `x-shibuya-upstream-tracestate`.

A downstream DLQ consumer's trace will therefore link to the
failing consumer's `processOne` span — exactly what you want for a
DLQ post-mortem. The original producer is one header lookup away
if you ever need to walk further up.

When tracing is disabled (`runTracingNoop`), the adapter forwards
the original headers verbatim — no behavior change for non-traced
deployments.

### DLQ writes (kafka)

The Kafka adapter does not implement DLQ today; `AckDeadLetter`
just stores the offset (see `kafka-adapter/src/Shibuya/Adapter/Kafka/Internal.hs`).
When DLQ lands, it should follow the same pattern as pgmq.


## Adapter authors: populating the two fields

If you're writing a new adapter (not just consuming one), populate
both fields at envelope-construction time inside your `Convert.hs`:

```haskell
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import OpenTelemetry.Attributes (Attribute, toAttribute)
import Shibuya.Core.Types (Envelope (..), Headers, TraceHeaders)

myAdapterToEnvelope :: NativeMessage -> Envelope MyPayload
myAdapterToEnvelope msg =
  Envelope
    { messageId    = mkMessageId msg
    , cursor       = Just (CursorInt msg.offset)
    , partition    = Just (Text.pack (show msg.partitionId))
    , enqueuedAt   = Just msg.timestamp
    , traceContext = extractTraceHeaders msg.headers   -- W3C in
    , headers      = Just msg.headers                   -- all broker headers
    , attempt      = Nothing                            -- if no redelivery counter
    , attributes   = mkAttributes msg                   -- typed labels out
    , payload      = msg.body
    }

extractTraceHeaders :: Headers -> Maybe TraceHeaders
extractTraceHeaders hdrs =
  case (lookup "traceparent" hdrs, lookup "tracestate" hdrs) of
    (Nothing, _)        -> Nothing
    (Just tp, Nothing)  -> Just [("traceparent", tp)]
    (Just tp, Just ts)  -> Just [("traceparent", tp), ("tracestate", ts)]

mkAttributes :: NativeMessage -> HashMap Text Attribute
mkAttributes msg =
  HashMap.fromList
    [ ("messaging.system", toAttribute @Text "my-system")
    -- typed broker-specific keys here, if your broker has any
    ]
```

Rules of thumb:

-   **`traceContext`** — extract `traceparent` from queue-native
    headers. Return `Nothing` if absent or malformed; the framework
    will treat the per-message span as a root.
-   **`attributes`** — populate **only** the keys your broker uniquely
    contributes. Don't duplicate `messaging.destination.name`,
    `messaging.operation.type`, or `messaging.message.id` — the framework
    derives those from the `ProcessorId` and the envelope's
    `MessageId`. **Do** override `messaging.system` if your broker
    isn't generic Shibuya.
-   **Use typed values when you have them.** `toAttribute @Int64 42`
    produces an `IntAttribute`, which Jaeger filters numerically;
    `toAttribute @Text "42"` produces a string and breaks numeric
    queries.
-   **An empty HashMap is fine** if your queue has no spec-defined
    typed conventions — that's what the pgmq adapter does today.

For producer-side code (publishing or DLQ writes), call
`currentTraceHeaders` to get the consumer's outgoing headers; merge
with the original message's headers per your propagation rule (the
pgmq adapter's `mergeDlqHeaders` is a worked example).


## Local Jaeger setup

Each adapter ships a `process-compose.yaml` that brings up a local
Jaeger instance:

```bash
just process-up        # starts Jaeger + the adapter's dependencies
```

Jaeger UI is on `http://127.0.0.1:16686`. The OTLP endpoint is on
`http://127.0.0.1:4318` (HTTP) or `:4317` (gRPC). Set
`OTEL_EXPORTER_OTLP_ENDPOINT` accordingly:

```bash
export OTEL_SERVICE_NAME="my-shibuya-consumer"
export OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4318"
cabal run my-consumer
```

Produce a test message with a known `traceparent` and you should
see one Consumer-kind span in the UI per message, parented on the
producer's span when present.

For Kafka via `rpk`:

```bash
rpk topic produce orders --key k1 \
  -H 'traceparent=00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01' \
  <<< 'hello-otel'
```

For pgmq via `psql`:

```sql
SELECT pgmq.send(
  'orders',
  '{"hello": "world"}'::jsonb,
  '{"traceparent": "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"}'::jsonb,
  0
);
```

## Reference

### Span attribute keys

The framework always sets these on its per-message span:

| Key | Type | Source |
|-----|------|--------|
| `messaging.system` | Text | `"shibuya"` (overridable by adapter) |
| `messaging.destination.name` | Text | `ProcessorId` |
| `messaging.operation.type` | Text | Always `"process"` |
| `messaging.message.id` | Text | `Envelope.messageId` |
| `shibuya.partition` | Text | `Envelope.partition` (when present) |
| `shibuya.inflight.count` | Int | Current in-flight count |
| `shibuya.inflight.max` | Int | Max concurrency |
| `shibuya.ack.decision` | Text | `"ack_ok"` / `"ack_retry"` / `"ack_dead_letter"` / `"ack_halt"` / `"error"` |

The Kafka adapter additionally sets, via `Envelope.attributes`:

| Key | Type | Source |
|-----|------|--------|
| `messaging.system` | Text | `"kafka"` (overrides framework default) |
| `messaging.kafka.destination.partition` | Int64 | `crPartition` |
| `messaging.kafka.message.offset` | Int64 | `crOffset` |

### Span events

| Event | When |
|-------|------|
| `shibuya.handler.started` | Right before the handler is called |
| `shibuya.handler.completed` | After the handler returns successfully |
| `shibuya.ack.decision` | If the handler threw an exception |
| `exception` | Standard OTel event, emitted by `recordException` on handler failure |

### Span name

The span name is `"<destination> process"`, where `<destination>` is
the `ProcessorId` text. This follows the OpenTelemetry messaging-spans
spec recommendation of `<destination> <operation>`.

### Useful module imports

```haskell
import Shibuya.Telemetry.Effect
  ( Tracing, runTracing, runTracingNoop
  , withSpan, withSpan'
  , addAttribute, addAttributes, addEvent, recordException, setStatus
  , isTracingEnabled, getTracer, withExtractedContext
  )
import Shibuya.Telemetry.Propagation
  ( extractTraceContext, injectTraceContext, currentTraceHeaders
  , TraceHeaders
  )
import Shibuya.Telemetry.Semantic
  ( consumerSpanArgs, internalSpanArgs
  , processSpanName, ingestSpanName
  )
```


## See also

-   [Getting Started](./getting-started.md) — handlers, ack
    decisions, `runApp`.
-   [OpenTelemetry messaging semantic conventions](https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/)
-   [W3C Trace Context](https://www.w3.org/TR/trace-context/)
