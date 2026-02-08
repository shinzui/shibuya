# OpenTelemetry Integration Plan for Shibuya

This document outlines the plan for integrating OpenTelemetry (OTel) into shibuya-core using the [hs-opentelemetry](https://github.com/iand675/hs-opentelemetry) library.

## Table of Contents

1. [Goals & Non-Goals](#goals--non-goals)
2. [hs-opentelemetry Overview](#hs-opentelemetry-overview)
3. [Architecture](#architecture)
4. [Effect Integration](#effect-integration)
5. [Tracing Instrumentation](#tracing-instrumentation)
6. [Context Propagation](#context-propagation)
7. [Configuration](#configuration)
8. [Implementation Phases](#implementation-phases)
9. [Testing Strategy](#testing-strategy)
10. [Performance Considerations](#performance-considerations)
11. [Future Work: Metrics Integration](#future-work-metrics-integration)

---

## Goals & Non-Goals

### Goals

- **Distributed Tracing**: Enable end-to-end request tracing from message ingestion through processing to ack decision
- **Context Propagation**: Support W3C trace context propagation from upstream message producers
- **Effectful Integration**: Provide a clean effect-based API that fits Shibuya's architecture
- **Minimal Overhead**: Keep instrumentation lightweight for high-throughput scenarios

### Non-Goals

- Replacing the existing metrics system (hs-opentelemetry does not support metrics yet; Prometheus remains our metrics solution)
- Automatic instrumentation of user handlers (opt-in only)
- Logging integration (separate concern)

---

## hs-opentelemetry Overview

### Core Packages

| Package | Purpose |
|---------|---------|
| `hs-opentelemetry-api` | Core API types (Span, Tracer, Context) |
| `hs-opentelemetry-sdk` | SDK implementation with providers |
| `hs-opentelemetry-exporter-otlp` | OTLP HTTP/gRPC exporter |
| `hs-opentelemetry-propagator-w3c` | W3C TraceContext propagation |

### Key Types

```haskell
-- From hs-opentelemetry-api
data Span = Span
  { spanContext :: SpanContext
  , spanName :: Text
  , spanKind :: SpanKind
  , spanStatus :: SpanStatus
  , ...
  }

data SpanContext = SpanContext
  { traceId :: TraceId      -- 16 bytes
  , spanId :: SpanId        -- 8 bytes
  , traceFlags :: TraceFlags
  , traceState :: TraceState
  }

-- Tracer for creating spans
data Tracer = Tracer { ... }

-- TracerProvider manages tracers
data TracerProvider = TracerProvider { ... }
```

---

## Architecture

### Current Architecture

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Adapter    │────▶│   Ingester   │────▶│  Processor   │
│   (source)   │     │   (async)    │     │  (handler)   │
└──────────────┘     └──────────────┘     └──────────────┘
                            │                    │
                            ▼                    ▼
                     ┌──────────────────────────────┐
                     │      ProcessorMetrics        │
                     │         (TVar)               │
                     └──────────────────────────────┘
                                  │
                                  ▼
                     ┌──────────────────────────────┐
                     │      Metrics Server          │
                     │  (Prometheus/JSON/WebSocket) │
                     └──────────────────────────────┘
```

### Proposed Architecture with OTel

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Adapter    │────▶│   Ingester   │────▶│  Processor   │
│   (source)   │     │   (async)    │     │  (handler)   │
└──────────────┘     └──────────────┘     └──────────────┘
       │                    │                    │
       │              [Span: ingest]      [Span: process]
       │                    │                    │
       │                    ▼                    ▼
       │             ┌──────────────────────────────┐
       │             │        OTel Effect           │
       │             │         (Tracer)             │
       │             └──────────────────────────────┘
       │                           │
       │                           ▼
       │                      ┌────────┐
       │                      │ Traces │
       │                      │ (OTLP) │
       │                      └────────┘
       │
       │             ┌──────────────────────────────┐
       │             │      ProcessorMetrics        │ ◀── existing (unchanged)
       │             │         (TVar)               │
       │             └──────────────────────────────┘
       │                           │
       ▼                           ▼
┌────────────────┐    ┌──────────────────────────────┐
│ TraceContext   │    │      Metrics Server          │
│ (from headers) │    │  (Prometheus/JSON/WebSocket) │
└────────────────┘    └──────────────────────────────┘
```

**Note**: hs-opentelemetry does not yet support metrics. Prometheus remains our metrics solution via the existing shibuya-metrics package.

---

## Effect Integration

### New Effect: `Telemetry`

Create a new effectful effect that encapsulates OTel functionality:

```haskell
-- Shibuya/Telemetry/Effect.hs
module Shibuya.Telemetry.Effect
  ( Telemetry
  , runTelemetry
  , runTelemetryNoop
  , withSpan
  , withSpan_
  , addEvent
  , addAttribute
  , recordException
  , getTracer
  , getCurrentSpan
  ) where

import Effectful
import Effectful.Dispatch.Dynamic
import OpenTelemetry.Trace qualified as OTel

-- | Telemetry effect for OpenTelemetry operations
data Telemetry :: Effect where
  WithSpan
    :: Text                          -- span name
    -> SpanKind                      -- kind
    -> [(Text, Attribute)]           -- attributes
    -> (Span -> m a)                 -- action
    -> Telemetry m a
  AddEvent
    :: Span
    -> Text                          -- event name
    -> [(Text, Attribute)]           -- attributes
    -> Telemetry m ()
  AddAttribute
    :: Span
    -> Text
    -> Attribute
    -> Telemetry m ()
  RecordException
    :: Span
    -> SomeException
    -> Telemetry m ()
  GetCurrentSpan
    :: Telemetry m (Maybe Span)

type instance DispatchOf Telemetry = 'Dynamic

-- | Run telemetry with actual OTel provider
runTelemetry
  :: (IOE :> es)
  => TracerProvider
  -> Text                            -- service name
  -> Eff (Telemetry : es) a
  -> Eff es a

-- | Run telemetry as no-op (for testing/disabled mode)
runTelemetryNoop
  :: Eff (Telemetry : es) a
  -> Eff es a
```

### Integration with Existing Effects

The `Telemetry` effect should be optional in the effect stack:

```haskell
-- Handler with optional telemetry
type Handler es msg = Ingested es msg -> Eff es AckDecision

-- Processing functions gain Telemetry constraint when enabled
processOne
  :: (IOE :> es, Telemetry :> es)
  => TVar ProcessorMetrics
  -> Handler es msg
  -> Ingested es msg
  -> Eff es ()
```

### Backward Compatibility

To maintain backward compatibility, we'll use constraint aliases:

```haskell
-- When telemetry is disabled, use this constraint
type NoTelemetry es = ()

-- When telemetry is enabled, use this constraint
type WithTelemetry es = Telemetry :> es

-- Conditional compilation or runtime flag
#ifdef ENABLE_TELEMETRY
type TelemetryConstraint es = WithTelemetry es
#else
type TelemetryConstraint es = NoTelemetry es
#endif
```

---

## Tracing Instrumentation

### Span Hierarchy

```
[shibuya.processor] (root span - processor lifetime)
├── [shibuya.ingest] (child - ingester thread)
│   └── [shibuya.ingest.message] (event - each message received)
│
└── [shibuya.process] (child - processing thread)
    ├── [shibuya.process.message] (child - single message)
    │   ├── [handler] (child - user handler execution)
    │   └── [shibuya.ack] (event - ack decision)
    │
    └── [shibuya.halt] (event - if halt occurs)
```

### Span Definitions

#### 1. Processor Span (Root)

**Location**: `Shibuya.Runner.Supervised.runSupervised`

```haskell
-- Attributes
shibuya.processor.id       :: Text      -- ProcessorId
shibuya.processor.adapter  :: Text      -- Adapter name
shibuya.concurrency.mode   :: Text      -- Serial/Ahead/Async
shibuya.concurrency.limit  :: Int       -- Max concurrency
shibuya.ordering           :: Text      -- StrictInOrder/PartitionedInOrder/Unordered

-- Events
processor.started          -- When processor begins
processor.stopped          -- When processor ends (with reason)
```

#### 2. Ingest Span

**Location**: `Shibuya.Runner.Ingester.runIngesterWithMetrics`

```haskell
-- Attributes
shibuya.ingest.batch_size  :: Int       -- If batched

-- Events (per message)
message.received           -- With message_id, timestamp
message.queued             -- When sent to inbox
backpressure.detected      -- When inbox send blocks
```

#### 3. Process Message Span

**Location**: `Shibuya.Runner.Supervised.processOne`

```haskell
-- Attributes
shibuya.message.id         :: Text      -- MessageId from Envelope
shibuya.message.partition  :: Text      -- Optional partition
shibuya.message.enqueued   :: UTCTime   -- Original enqueue time
shibuya.inflight.count     :: Int       -- Current in-flight count
shibuya.inflight.max       :: Int       -- Max concurrency

-- Events
processing.started         -- State → Processing
handler.started            -- Before handler call
handler.completed          -- After handler returns
handler.exception          -- If handler throws
ack.decision               -- With decision type and reason
processing.completed       -- State → Idle/Failed
```

#### 4. Handler Span (Optional)

**Location**: User-provided, instrumented via helper

```haskell
-- Helper for users to instrument their handlers
instrumentHandler
  :: (Telemetry :> es)
  => Text                              -- handler name
  -> Handler es msg
  -> Handler es msg
instrumentHandler name handler ingested =
  withSpan ("handler." <> name) SpanKindInternal [] $ \span -> do
    addAttribute span "message.id" (toAttribute ingested.envelope.messageId)
    handler ingested
```

### Instrumentation Code Examples

#### Ingester Instrumentation

```haskell
-- Shibuya/Runner/Ingester.hs
runIngesterWithMetrics
  :: (IOE :> es, Telemetry :> es)
  => TVar ProcessorMetrics
  -> ProcessorId
  -> Stream (Eff es) (Ingested es msg)
  -> Inbox (Ingested es msg)
  -> Eff es ()
runIngesterWithMetrics metricsVar procId source inbox =
  withSpan "shibuya.ingest" SpanKindConsumer
    [("shibuya.processor.id", toAttribute procId)] $ \ingestSpan -> do
    Stream.fold Fold.drain $
      Stream.mapM (ingestMessage ingestSpan) source
  where
    ingestMessage span ingested = do
      now <- liftIO getCurrentTime

      -- Record metric
      liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
        m {stats = incReceived m.stats}

      -- Add trace event
      addEvent span "message.received"
        [ ("message.id", toAttribute ingested.envelope.messageId)
        , ("timestamp", toAttribute now)
        ]

      -- Send to inbox (may block)
      liftIO $ send inbox ingested

      addEvent span "message.queued"
        [("message.id", toAttribute ingested.envelope.messageId)]
```

#### Process One Instrumentation

```haskell
-- Shibuya/Runner/Supervised.hs
processOne
  :: (IOE :> es, Telemetry :> es)
  => TVar ProcessorMetrics
  -> Int
  -> IORef (Maybe HaltReason)
  -> Handler es msg
  -> Ingested es msg
  -> Eff es ()
processOne metricsVar maxConc haltRef handler ingested = do
  let msgId = ingested.envelope.messageId

  -- Create processing span, linking to any parent context from message
  parentCtx <- extractTraceContext ingested.envelope

  withSpanOpts "shibuya.process.message" SpanKindConsumer
    (defaultSpanOpts { parentContext = parentCtx })
    [ ("shibuya.message.id", toAttribute msgId)
    , ("shibuya.message.partition", toAttribute $ fromMaybe "" ingested.envelope.partition)
    ] $ \span -> do

    now <- liftIO getCurrentTime

    -- Update state to Processing
    (current, _) <- liftIO $ atomically $ do
      m <- readTVar metricsVar
      let current = currentInFlight m
      modifyTVar' metricsVar $ \m' ->
        m' & #state .~ Processing (InFlightInfo (current + 1) maxConc) now
      pure (current, m)

    addAttribute span "shibuya.inflight.count" (toAttribute $ current + 1)
    addAttribute span "shibuya.inflight.max" (toAttribute maxConc)
    addEvent span "processing.started" []

    -- Execute handler with tracing
    addEvent span "handler.started" []
    result <- try @SomeException $ handler ingested

    case result of
      Left ex -> do
        recordException span ex
        addEvent span "handler.exception" [("exception.message", toAttribute $ show ex)]
        -- Handle exception...

      Right decision -> do
        addEvent span "handler.completed" []

        -- Finalize ack
        ingested.ack.finalize decision

        -- Record ack decision
        addEvent span "ack.decision"
          [ ("decision.type", toAttribute $ ackDecisionType decision)
          , ("decision.reason", toAttribute $ ackDecisionReason decision)
          ]

        -- Update metrics and check halt
        endNow <- liftIO getCurrentTime
        decrementAndUpdate metricsVar decision endNow

        addEvent span "processing.completed" []

        case decision of
          AckHalt reason -> do
            addEvent span "halt.requested" [("reason", toAttribute reason)]
            liftIO $ atomicWriteIORef haltRef (Just reason)
          _ -> pure ()
```

---

## Context Propagation

### W3C TraceContext

Support extracting trace context from message headers:

```haskell
-- Shibuya/Telemetry/Propagation.hs
module Shibuya.Telemetry.Propagation
  ( extractTraceContext
  , injectTraceContext
  , TraceHeaders
  ) where

import OpenTelemetry.Propagator.W3CTraceContext

-- Headers that may contain trace context
type TraceHeaders = Map Text Text

-- Extend Envelope to optionally carry headers
data Envelope msg = Envelope
  { messageId :: !MessageId
  , cursor :: !(Maybe Cursor)
  , partition :: !(Maybe Text)
  , enqueuedAt :: !(Maybe UTCTime)
  , headers :: !(Maybe TraceHeaders)   -- NEW: for trace propagation
  , payload :: !msg
  }

-- Extract parent context from message headers
extractTraceContext :: Maybe TraceHeaders -> IO (Maybe SpanContext)
extractTraceContext Nothing = pure Nothing
extractTraceContext (Just headers) = do
  let getter = MapCarrier headers
  propagator <- getW3CTraceContextPropagator
  extract propagator getter

-- Inject current context into headers (for producing messages)
injectTraceContext :: SpanContext -> IO TraceHeaders
injectTraceContext ctx = do
  propagator <- getW3CTraceContextPropagator
  inject propagator ctx (MapCarrier mempty)
```

### Adapter Integration

Adapters need to extract headers from their source:

```haskell
-- Example for a hypothetical SQS adapter
sqsToIngested :: SQS.Message -> Ingested es SQSPayload
sqsToIngested msg = Ingested
  { envelope = Envelope
      { messageId = MessageId msg.messageId
      , headers = Just $ extractSQSHeaders msg.messageAttributes
      , ...
      }
  , ...
  }
```

---

## Configuration

### TelemetryConfig

```haskell
-- Shibuya/Telemetry/Config.hs
module Shibuya.Telemetry.Config
  ( TelemetryConfig (..)
  , defaultTelemetryConfig
  , SamplingStrategy (..)
  ) where

data TelemetryConfig = TelemetryConfig
  { enabled :: !Bool
  , serviceName :: !Text
  , serviceVersion :: !(Maybe Text)
  , sampling :: !SamplingStrategy
  , exporterEndpoint :: !(Maybe Text)      -- OTLP endpoint
  , exporterHeaders :: !(Map Text Text)    -- Auth headers
  , batchSize :: !Int                      -- Span batch size
  , exportIntervalMs :: !Int               -- Export interval
  }

data SamplingStrategy
  = AlwaysOn                               -- Sample everything
  | AlwaysOff                              -- Sample nothing
  | TraceIdRatioBased Double               -- Probabilistic (0.0-1.0)
  | ParentBased SamplingStrategy           -- Follow parent decision
  deriving stock (Eq, Show, Generic)

defaultTelemetryConfig :: TelemetryConfig
defaultTelemetryConfig = TelemetryConfig
  { enabled = False                        -- Opt-in
  , serviceName = "shibuya"
  , serviceVersion = Nothing
  , sampling = ParentBased (TraceIdRatioBased 0.1)  -- 10% default
  , exporterEndpoint = Nothing             -- Use OTEL_EXPORTER_OTLP_ENDPOINT env
  , exporterHeaders = mempty
  , batchSize = 512
  , exportIntervalMs = 5000
  }
```

### Environment Variables

Support standard OTel environment variables:

| Variable | Purpose |
|----------|---------|
| `OTEL_SERVICE_NAME` | Service name |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint URL |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers |
| `OTEL_TRACES_SAMPLER` | Sampling strategy |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument |

---

## Implementation Phases

### Phase 1: Foundation

**Goal**: Core infrastructure without changing existing behavior

1. **Add dependencies to cabal file**
   ```cabal
   -- shibuya-core.cabal
   build-depends:
     , hs-opentelemetry-api ^>=0.1
     , hs-opentelemetry-sdk ^>=0.0.3

   -- shibuya-telemetry.cabal (new package)
   build-depends:
     , hs-opentelemetry-api ^>=0.1
     , hs-opentelemetry-sdk ^>=0.0.3
     , hs-opentelemetry-exporter-otlp ^>=0.0.1
     , hs-opentelemetry-propagator-w3c ^>=0.0.1
   ```

2. **Create Telemetry effect module**
   - `Shibuya.Telemetry.Effect`
   - `runTelemetry` and `runTelemetryNoop` interpreters

3. **Create configuration types**
   - `Shibuya.Telemetry.Config`
   - Environment variable parsing

4. **Add headers field to Envelope**
   - Non-breaking: `headers :: Maybe TraceHeaders`

**Deliverables**:
- New `shibuya-telemetry` package
- Effect and config types
- No behavioral changes to existing code

### Phase 2: Tracing

**Goal**: Instrument core processing paths

1. **Instrument Supervised.hs**
   - Processor span (root)
   - Process message span
   - Ack decision events

2. **Instrument Ingester.hs**
   - Ingest span
   - Message received events

3. **Add context propagation**
   - Extract from Envelope headers
   - Link spans to parent context

4. **Create helper for handler instrumentation**
   - `instrumentHandler` function

**Deliverables**:
- Full tracing instrumentation
- Context propagation working
- Example with Jaeger/Zipkin

### Phase 3: Polish & Documentation

**Goal**: Production readiness

1. **Performance testing**
   - Benchmark tracing overhead
   - Tune batch sizes and intervals

2. **Documentation**
   - Integration guide
   - Configuration reference
   - Troubleshooting guide

3. **Examples**
   - shibuya-example with OTel enabled
   - Docker Compose with Jaeger/Grafana

4. **Testing**
   - Unit tests for Telemetry effect
   - Integration tests with mock exporter

**Deliverables**:
- Complete documentation
- Performance benchmarks
- Docker Compose example stack

---

## Testing Strategy

### Unit Tests

```haskell
-- test/Shibuya/Telemetry/EffectSpec.hs
spec :: Spec
spec = describe "Telemetry Effect" $ do

  describe "runTelemetryNoop" $ do
    it "executes actions without tracing" $ do
      result <- runEff $ runTelemetryNoop $ do
        withSpan "test" SpanKindInternal [] $ \_ -> do
          pure (42 :: Int)
      result `shouldBe` 42

  describe "runTelemetry" $ do
    it "creates spans with correct attributes" $ do
      (spans, _) <- withMockExporter $ \provider -> do
        runEff $ runTelemetry provider "test-service" $ do
          withSpan "my-span" SpanKindInternal
            [("key", toAttribute "value")] $ \_ -> do
            pure ()

      length spans `shouldBe` 1
      (head spans).name `shouldBe` "my-span"
```

### Integration Tests

```haskell
-- test/Shibuya/Telemetry/IntegrationSpec.hs
spec :: Spec
spec = describe "OTel Integration" $ do

  it "propagates trace context through processing" $ do
    (spans, _) <- withMockExporter $ \provider -> do
      let config = defaultAppConfig
            { telemetry = defaultTelemetryConfig { enabled = True }
            }

      runApp config $ do
        -- Send message with trace context
        sendTestMessage testMessageWithTraceHeaders

        -- Wait for processing
        waitForProcessing

    -- Verify span hierarchy
    let processorSpan = find ((== "shibuya.processor") . (.name)) spans
    let messageSpan = find ((== "shibuya.process.message") . (.name)) spans

    messageSpan `shouldSatisfy` isJust
    (fromJust messageSpan).parentSpanId `shouldBe` (fromJust processorSpan).spanId
```

### Benchmarks

```haskell
-- bench/TelemetryBench.hs
main :: IO ()
main = defaultMain
  [ bgroup "processing"
      [ bench "without telemetry" $ nfIO (runWithoutTelemetry 10000)
      , bench "with telemetry (noop)" $ nfIO (runWithNoopTelemetry 10000)
      , bench "with telemetry (sampling 10%)" $ nfIO (runWithTelemetry 0.1 10000)
      , bench "with telemetry (sampling 100%)" $ nfIO (runWithTelemetry 1.0 10000)
      ]
  ]
```

---

## Performance Considerations

### Overhead Mitigation

1. **Sampling**: Default to 10% sampling rate
   - Use `ParentBased` to respect upstream decisions
   - Allow per-processor override

2. **Batching**: Batch span exports
   - Default 512 spans per batch
   - 5 second export interval

3. **Async Export**: Non-blocking span submission
   - Use bounded queue for backpressure
   - Drop spans if queue full (configurable)

4. **Lazy Attributes**: Defer attribute computation
   ```haskell
   -- Lazy attribute that only computes if sampling
   addLazyAttribute span "expensive" $ do
     computeExpensiveValue
   ```

5. **Noop Mode**: Zero overhead when disabled
   - `runTelemetryNoop` compiles to no-ops
   - No allocations for span creation

### Expected Overhead

| Scenario | Overhead |
|----------|----------|
| Telemetry disabled | ~0% |
| Telemetry enabled, 0% sampling | < 1% |
| Telemetry enabled, 10% sampling | 1-3% |
| Telemetry enabled, 100% sampling | 5-10% |

### Memory Considerations

- Span batches held in memory until export
- Configure `batchSize` based on available memory
- Monitor `shibuya.telemetry.queue_size` metric

---

## File Structure

After implementation:

```
shibuya-core/
  src/Shibuya/
    Core/
      Ingested.hs          # Updated: headers field in Envelope
    Telemetry/             # NEW
      Effect.hs            # Telemetry effect
      Config.hs            # Configuration types
      Propagation.hs       # Context propagation
      Internal.hs          # Internal utilities
    Runner/
      Supervised.hs        # Updated: instrumented
      Ingester.hs          # Updated: instrumented
      Master.hs            # Updated: instrumented
    App.hs                 # Updated: telemetry initialization

shibuya-telemetry/         # NEW optional package
  shibuya-telemetry.cabal
  src/Shibuya/
    Telemetry/
      OTLP.hs              # OTLP exporter setup
      Jaeger.hs            # Jaeger-specific helpers
      Honeycomb.hs         # Honeycomb-specific helpers

docs/
  guides/
    TELEMETRY.md           # User guide
  architecture/
    TELEMETRY_DESIGN.md    # This document
```

---

## Dependencies Summary

```cabal
-- shibuya-core.cabal additions
build-depends:
  , hs-opentelemetry-api ^>=0.1

-- shibuya-telemetry.cabal (new)
build-depends:
  , base ^>=4.18
  , shibuya-core
  , hs-opentelemetry-api ^>=0.1
  , hs-opentelemetry-sdk ^>=0.0.3
  , hs-opentelemetry-exporter-otlp ^>=0.0.1
  , hs-opentelemetry-propagator-w3c ^>=0.0.1
  , effectful ^>=2.6
  , text ^>=2.1
  , containers ^>=0.7
  , time ^>=1.12
```

---

## Open Questions

1. **Logging Integration**: Should we integrate with hs-opentelemetry-instrumentation-logging?
   - Deferred: Keep logging separate for now

2. **Baggage Propagation**: Support W3C Baggage alongside TraceContext?
   - Recommend: Yes, useful for passing metadata

3. **Resource Detection**: Auto-detect Kubernetes/cloud metadata?
   - Recommend: Support via environment variables initially

4. **Custom Span Processors**: Allow users to add custom processors?
   - Recommend: Yes, via configuration hook

---

## Future Work: Metrics Integration

When hs-opentelemetry adds metrics support, we can extend the integration to export metrics via OTLP alongside Prometheus.

### Future Architecture with Metrics

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   Adapter    │────▶│   Ingester   │────▶│  Processor   │
│   (source)   │     │   (async)    │     │  (handler)   │
└──────────────┘     └──────────────┘     └──────────────┘
       │                    │                    │
       │              [Span: ingest]      [Span: process]
       │                    │                    │
       │                    ▼                    ▼
       │             ┌──────────────────────────────┐
       │             │        OTel Effect           │
       │             │   (Tracer + MeterProvider)   │
       │             └──────────────────────────────┘
       │                           │
       │    ┌──────────────────────┼──────────────────────┐
       │    │                      │                      │
       │    ▼                      ▼                      ▼
       │ ┌────────┐         ┌────────────┐         ┌────────────┐
       │ │ Traces │         │  Metrics   │         │    Logs    │
       │ │ (OTLP) │         │   (OTLP)   │         │  (future)  │
       │ └────────┘         └────────────┘         └────────────┘
       │                           │
       │                           ▼
       │             ┌──────────────────────────────┐
       │             │      ProcessorMetrics        │
       │             │         (TVar)               │
       │             └──────────────────────────────┘
       │                           │
       ▼                           ▼
┌────────────────┐    ┌──────────────────────────────┐
│ TraceContext   │    │      Metrics Server          │
│ (from headers) │    │  (Prometheus + OTLP)         │
└────────────────┘    └──────────────────────────────┘
```

### OTel Metrics Mapping

Map existing `ProcessorMetrics` to OTel metrics:

| Shibuya Metric | OTel Metric Type | OTel Metric Name |
|----------------|------------------|------------------|
| `stats.received` | Counter | `shibuya.messages.received` |
| `stats.processed` | Counter | `shibuya.messages.processed` |
| `stats.failed` | Counter | `shibuya.messages.failed` |
| `stats.dropped` | Counter | `shibuya.messages.dropped` |
| `state` (Processing) | Gauge | `shibuya.inflight.count` |
| `startedAt` | Gauge | `shibuya.processor.uptime_seconds` |

### Metric Attributes (Labels)

All metrics should include:

```haskell
-- Common attributes for all metrics
processorId   :: Text    -- shibuya.processor.id
adapterType   :: Text    -- shibuya.adapter.type
```

### Future Implementation

```haskell
-- Shibuya/Telemetry/Metrics.hs
module Shibuya.Telemetry.Metrics
  ( OTelMetrics
  , initOTelMetrics
  , syncMetrics
  ) where

import OpenTelemetry.Metrics qualified as OTel

data OTelMetrics = OTelMetrics
  { receivedCounter  :: OTel.Counter Int
  , processedCounter :: OTel.Counter Int
  , failedCounter    :: OTel.Counter Int
  , droppedCounter   :: OTel.Counter Int
  , inflightGauge    :: OTel.ObservableGauge Int
  , uptimeGauge      :: OTel.ObservableGauge Double
  }

-- Initialize OTel metrics from MeterProvider
initOTelMetrics
  :: OTel.MeterProvider
  -> ProcessorId
  -> TVar ProcessorMetrics
  -> IO OTelMetrics

-- Periodically sync TVar metrics to OTel
-- (for observable gauges, this happens via callbacks)
syncMetrics :: OTelMetrics -> ProcessorMetrics -> IO ()
```

### Dual Export Strategy

When metrics support is available, keep both Prometheus and OTLP:

```haskell
-- Shibuya/Metrics/Server.hs (future update)
data MetricsServerConfig = MetricsServerConfig
  { port :: Int
  , prometheusEnabled :: Bool           -- existing
  , otlpMetricsEnabled :: Bool          -- future
  , otlpMetricsEndpoint :: Maybe Text   -- future
  }
```

---

## References

- [hs-opentelemetry GitHub](https://github.com/iand675/hs-opentelemetry)
- [OpenTelemetry Specification](https://opentelemetry.io/docs/specs/otel/)
- [W3C Trace Context](https://www.w3.org/TR/trace-context/)
- [effectful documentation](https://hackage.haskell.org/package/effectful)
