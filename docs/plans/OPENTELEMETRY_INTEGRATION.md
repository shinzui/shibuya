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
| `hs-opentelemetry-sdk` | SDK with TracerProvider, samplers, batch processor |
| `hs-opentelemetry-exporter-otlp` | OTLP HTTP/gRPC exporter |
| `hs-opentelemetry-propagator-w3c` | W3C TraceContext and Baggage propagation |

### Key Types

```haskell
-- Span variants (from OpenTelemetry.Trace.Core)
data Span
  = Span (IORef ImmutableSpan)   -- Recording span (mutable)
  | FrozenSpan SpanContext       -- Remote/parent span
  | Dropped SpanContext          -- Dropped by sampler

data SpanContext = SpanContext
  { traceFlags :: TraceFlags     -- W3C trace flags (sampled bit)
  , isRemote :: Bool             -- True if from remote service
  , traceId :: TraceId           -- 16-byte trace identifier
  , spanId :: SpanId             -- 8-byte span identifier
  , traceState :: TraceState     -- Vendor-specific state
  }

data SpanArguments = SpanArguments
  { kind :: SpanKind             -- Internal, Server, Client, Producer, Consumer
  , attributes :: AttributeMap
  , links :: [NewLink]
  , startTime :: Maybe Timestamp
  }

data SpanStatus = Unset | Error Text | Ok
```

### SDK Initialization

The SDK reads configuration from `OTEL_*` environment variables:

```haskell
-- High-level initialization (reads all env vars)
initializeGlobalTracerProvider :: IO TracerProvider
initializeTracerProvider :: IO TracerProvider

-- Shutdown (flushes pending spans)
shutdownTracerProvider :: TracerProvider -> IO ()
```

### Monadic API

hs-opentelemetry provides a `MonadTracer` class we can leverage:

```haskell
class (Monad m) => MonadTracer m where
  getTracer :: m Tracer

-- Span creation with automatic parent linking
inSpan :: (MonadUnliftIO m, MonadTracer m)
       => Text -> SpanArguments -> m a -> m a
inSpan' :: (MonadUnliftIO m, MonadTracer m)
        => Text -> SpanArguments -> (Span -> m a) -> m a
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

### Approach: Static Effect with Reader

Since hs-opentelemetry uses `MonadUnliftIO` and thread-local context, we'll use a simpler static effect pattern with a `Reader` carrying the `Tracer`:

```haskell
-- Shibuya/Telemetry/Effect.hs
module Shibuya.Telemetry.Effect
  ( Tracing
  , runTracing
  , runTracingNoop
  , withSpan
  , withSpan'
  , addEvent
  , addAttribute
  , addAttributes
  , recordException
  , setStatus
  ) where

import Effectful
import Effectful.Dispatch.Static
import OpenTelemetry.Trace qualified as OTel
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Monad qualified as OTel
import OpenTelemetry.Context.ThreadLocal qualified as Context

-- | Tracing effect - provides access to OTel Tracer
data Tracing :: Effect

type instance DispatchOf Tracing = 'Static 'WithSideEffects

data instance StaticRep Tracing = TracingRep
  { tracer :: !OTel.Tracer
  , enabled :: !Bool
  }

-- | Run with actual tracing
runTracing
  :: (IOE :> es)
  => OTel.Tracer
  -> Eff (Tracing : es) a
  -> Eff es a
runTracing t = evalStaticRep (TracingRep t True)

-- | Run with tracing disabled (zero overhead)
runTracingNoop
  :: (IOE :> es)
  => Eff (Tracing : es) a
  -> Eff es a
runTracingNoop = evalStaticRep (TracingRep noopTracer False)
  where
    noopTracer = OTel.makeTracer noopProvider "noop" OTel.defaultTracerOptions
    noopProvider = OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
```

### Core Operations

```haskell
-- | Create a span wrapping an action
withSpan
  :: (Tracing :> es, IOE :> es)
  => Text                    -- ^ Span name
  -> OTel.SpanArguments      -- ^ Span arguments (kind, attributes, links)
  -> Eff es a                -- ^ Action to trace
  -> Eff es a
withSpan name args action = do
  TracingRep{tracer, enabled} <- getStaticRep
  if not enabled
    then action
    else unsafeEff_ $ OTel.inSpan tracer name args (unsafeUnliftIO action)

-- | Create a span with access to the Span for adding attributes
withSpan'
  :: (Tracing :> es, IOE :> es)
  => Text
  -> OTel.SpanArguments
  -> (OTel.Span -> Eff es a)
  -> Eff es a
withSpan' name args f = do
  TracingRep{tracer, enabled} <- getStaticRep
  if not enabled
    then f OTel.dummySpan  -- or we could use a FrozenSpan
    else unsafeEff_ $ OTel.inSpan' tracer name args $ \span ->
           unsafeUnliftIO (f span)

-- | Add an attribute to a span
addAttribute
  :: (Tracing :> es, IOE :> es, OTel.ToAttribute a)
  => OTel.Span -> Text -> a -> Eff es ()
addAttribute span key val = liftIO $ OTel.addAttribute span key val

-- | Add multiple attributes
addAttributes
  :: (Tracing :> es, IOE :> es)
  => OTel.Span -> HashMap Text OTel.Attribute -> Eff es ()
addAttributes span attrs = liftIO $ OTel.addAttributes span attrs

-- | Add an event to a span
addEvent
  :: (Tracing :> es, IOE :> es)
  => OTel.Span -> OTel.NewEvent -> Eff es ()
addEvent span event = liftIO $ OTel.addEvent span event

-- | Record an exception
recordException
  :: (Tracing :> es, IOE :> es, Exception e)
  => OTel.Span -> e -> Eff es ()
recordException span ex = liftIO $
  OTel.recordException span mempty Nothing ex

-- | Set span status
setStatus
  :: (Tracing :> es, IOE :> es)
  => OTel.Span -> OTel.SpanStatus -> Eff es ()
setStatus span status = liftIO $ OTel.setStatus span status
```

### Helper: NewEvent Construction

```haskell
-- | Convenient event creation
mkEvent :: Text -> [(Text, OTel.Attribute)] -> OTel.NewEvent
mkEvent name attrs = OTel.NewEvent
  { OTel.newEventName = name
  , OTel.newEventAttributes = HashMap.fromList attrs
  , OTel.newEventTimestamp = Nothing  -- Use current time
  }
```

### Initialization

```haskell
-- Shibuya/Telemetry/Init.hs
module Shibuya.Telemetry.Init
  ( initTracing
  , withTracing
  , TracingConfig(..)
  ) where

import OpenTelemetry.Trace qualified as OTel

data TracingConfig = TracingConfig
  { serviceName :: !Text
  , serviceVersion :: !(Maybe Text)
  }

-- | Initialize tracing from environment variables
-- Reads: OTEL_SERVICE_NAME, OTEL_EXPORTER_OTLP_ENDPOINT, OTEL_TRACES_SAMPLER, etc.
initTracing :: TracingConfig -> IO (OTel.TracerProvider, OTel.Tracer)
initTracing cfg = do
  provider <- OTel.initializeTracerProvider
  let tracer = OTel.makeTracer provider
        (OTel.InstrumentationLibrary "shibuya" (cfg.serviceVersion))
        OTel.defaultTracerOptions
  pure (provider, tracer)

-- | Bracket for tracing lifecycle
withTracing
  :: TracingConfig
  -> (OTel.Tracer -> IO a)
  -> IO a
withTracing cfg action = bracket
  (initTracing cfg)
  (\(provider, _) -> OTel.shutdownTracerProvider provider)
  (\(_, tracer) -> action tracer)
```

### Integration with Shibuya App

```haskell
-- Updated Shibuya/App.hs
runApp
  :: AppConfig
  -> [QueueProcessor es]
  -> Eff es ()
runApp config processors = do
  -- Initialize tracing if enabled
  mTracer <- if config.telemetry.enabled
    then do
      (provider, tracer) <- liftIO $ initTracing config.telemetry
      pure (Just (provider, tracer))
    else pure Nothing

  -- Run with or without tracing
  case mTracer of
    Just (provider, tracer) -> do
      result <- runTracing tracer $ runAppInternal config processors
      liftIO $ OTel.shutdownTracerProvider provider
      pure result
    Nothing ->
      runTracingNoop $ runAppInternal config processors
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

#### 1. Process Message Span (Primary)

**Location**: `Shibuya.Runner.Supervised.processOne`

This is the main span we create per message. Using OTel semantic conventions for messaging:

```haskell
-- Span name and kind
name: "shibuya.process.message"
kind: SpanKind.Consumer

-- Attributes (OTel messaging semantic conventions)
messaging.system             :: "shibuya"
messaging.message.id         :: Text      -- MessageId from Envelope
messaging.destination.name   :: Text      -- ProcessorId
messaging.destination.partition.id :: Text -- Optional partition

-- Shibuya-specific attributes
shibuya.inflight.count       :: Int       -- Current in-flight count
shibuya.inflight.max         :: Int       -- Max concurrency
shibuya.ack.decision         :: Text      -- Final ack decision

-- Events
handler.started              -- Before handler call
handler.completed            -- After handler returns (with duration)
handler.exception            -- If handler throws

-- Status
Ok       -- AckOk, AckRetry
Error    -- AckDeadLetter, AckHalt, exceptions
```

#### 2. Ingest Span (Optional, Low-Overhead)

**Location**: `Shibuya.Runner.Ingester.runIngesterWithMetrics`

We create one span for the entire ingester lifecycle, not per-message (too expensive):

```haskell
-- Span
name: "shibuya.ingest"
kind: SpanKind.Consumer

-- Attributes
shibuya.processor.id         :: Text
messaging.system             :: "shibuya"

-- Note: Individual message events are NOT added here due to overhead.
-- Per-message tracing happens in processOne with parent context propagation.
```

#### 3. Handler Span (User-Provided)

Users can optionally wrap their handlers:

```haskell
-- Helper for users to instrument their handlers
instrumentHandler
  :: (Tracing :> es, IOE :> es)
  => Text                              -- handler name
  -> Handler es msg
  -> Handler es msg
instrumentHandler name handler ingested =
  withSpan' ("handler." <> name) internalSpanArgs $ \span -> do
    addAttribute span "messaging.message.id" ingested.envelope.messageId
    handler ingested

internalSpanArgs :: OTel.SpanArguments
internalSpanArgs = OTel.SpanArguments
  { kind = OTel.Internal
  , attributes = mempty
  , links = []
  , startTime = Nothing
  }
```

### SpanArguments Helpers

```haskell
-- Shibuya/Telemetry/Semantic.hs

-- | SpanArguments for message processing (consumer)
consumerSpanArgs :: Ingested es msg -> OTel.SpanArguments
consumerSpanArgs ingested = OTel.SpanArguments
  { kind = OTel.Consumer
  , attributes = HashMap.fromList
      [ ("messaging.system", OTel.toAttribute @Text "shibuya")
      , ("messaging.message.id", OTel.toAttribute ingested.envelope.messageId)
      ]
  , links = []
  , startTime = Nothing
  }

-- | SpanArguments for ingester (also consumer)
ingesterSpanArgs :: ProcessorId -> OTel.SpanArguments
ingesterSpanArgs procId = OTel.SpanArguments
  { kind = OTel.Consumer
  , attributes = HashMap.fromList
      [ ("messaging.system", OTel.toAttribute @Text "shibuya")
      , ("shibuya.processor.id", OTel.toAttribute procId)
      ]
  , links = []
  , startTime = Nothing
  }
```

---

## Context Propagation

### W3C TraceContext

hs-opentelemetry provides W3C trace context propagation out of the box:

```haskell
-- Shibuya/Telemetry/Propagation.hs
module Shibuya.Telemetry.Propagation
  ( extractTraceContext
  , injectTraceContext
  , withExtractedContext
  , TraceHeaders
  ) where

import OpenTelemetry.Context qualified as Context
import OpenTelemetry.Context.ThreadLocal qualified as Context
import OpenTelemetry.Propagator.W3CTraceContext qualified as W3C
import OpenTelemetry.Trace.Core qualified as OTel
import Data.ByteString (ByteString)

-- | Headers containing trace context (traceparent, tracestate)
type TraceHeaders = [(ByteString, ByteString)]

-- | Extract SpanContext from W3C headers
extractTraceContext :: TraceHeaders -> Maybe OTel.SpanContext
extractTraceContext headers =
  let traceparent = lookup "traceparent" headers
      tracestate = lookup "tracestate" headers
  in W3C.decodeSpanContext traceparent tracestate

-- | Inject current context into headers
injectTraceContext :: OTel.SpanContext -> TraceHeaders
injectTraceContext ctx =
  let (traceparent, tracestate) = W3C.encodeSpanContext ctx
  in [("traceparent", traceparent), ("tracestate", tracestate)]

-- | Run action with extracted parent context
withExtractedContext
  :: (IOE :> es)
  => Maybe OTel.SpanContext
  -> Eff es a
  -> Eff es a
withExtractedContext Nothing action = action
withExtractedContext (Just parentCtx) action = do
  -- Wrap the remote SpanContext as a FrozenSpan and insert into context
  let parentSpan = OTel.wrapSpanContext parentCtx
  liftIO $ Context.adjustContext (Context.insertSpan parentSpan)
  result <- action
  liftIO $ Context.adjustContext Context.removeSpan
  pure result
```

### Updated Envelope

```haskell
-- Shibuya/Core/Ingested.hs
data Envelope msg = Envelope
  { messageId :: !MessageId
  , cursor :: !(Maybe Cursor)
  , partition :: !(Maybe Text)
  , enqueuedAt :: !(Maybe UTCTime)
  , traceContext :: !(Maybe TraceHeaders)  -- NEW: W3C trace headers
  , payload :: !msg
  }
```

### Adapter Integration

Adapters extract trace headers from their queue-specific format:

```haskell
-- Example: SQS adapter extracts from message attributes
sqsToIngested :: SQS.Message -> Ingested es SQSPayload
sqsToIngested msg = Ingested
  { envelope = Envelope
      { messageId = MessageId msg.messageId
      , traceContext = extractSQSTraceHeaders msg.messageAttributes
      , ...
      }
  , ...
  }

-- Example: Kafka adapter extracts from record headers
kafkaToIngested :: Kafka.ConsumerRecord -> Ingested es KafkaPayload
kafkaToIngested record = Ingested
  { envelope = Envelope
      { messageId = MessageId (show record.offset)
      , traceContext = Just record.headers  -- Kafka headers are already [(BS, BS)]
      , ...
      }
  , ...
  }
```

### Usage in Processing

```haskell
processOne ingested = do
  -- Extract parent context from message headers
  let parentCtx = ingested.envelope.traceContext >>= extractTraceContext

  -- Create span linked to parent
  withExtractedContext parentCtx $
    withSpan' "shibuya.process.message" consumerArgs $ \span -> do
      addAttribute span "messaging.message.id" ingested.envelope.messageId
      -- ... process message
```

---

## Configuration

### TracingConfig

Shibuya's tracing config is minimal since hs-opentelemetry reads most settings from environment variables:

```haskell
-- Shibuya/Telemetry/Config.hs
module Shibuya.Telemetry.Config
  ( TracingConfig (..)
  , defaultTracingConfig
  ) where

data TracingConfig = TracingConfig
  { enabled :: !Bool               -- Master switch for tracing
  , serviceName :: !Text           -- Fallback if OTEL_SERVICE_NAME not set
  , serviceVersion :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

defaultTracingConfig :: TracingConfig
defaultTracingConfig = TracingConfig
  { enabled = False                -- Opt-in by default
  , serviceName = "shibuya"
  , serviceVersion = Nothing
  }
```

### Environment Variables (handled by hs-opentelemetry-sdk)

The SDK automatically reads these environment variables via `initializeTracerProvider`:

**General:**
| Variable | Purpose | Default |
|----------|---------|---------|
| `OTEL_SDK_DISABLED` | Disable SDK entirely | `false` |
| `OTEL_SERVICE_NAME` | Service name | `unknown_service` |
| `OTEL_RESOURCE_ATTRIBUTES` | Additional resource attrs | - |

**Sampling:**
| Variable | Purpose | Default |
|----------|---------|---------|
| `OTEL_TRACES_SAMPLER` | Sampler type | `parentbased_always_on` |
| `OTEL_TRACES_SAMPLER_ARG` | Sampler argument | - |

Sampler values: `always_on`, `always_off`, `traceidratio`, `parentbased_always_on`, `parentbased_always_off`, `parentbased_traceidratio`

**OTLP Exporter:**
| Variable | Purpose | Default |
|----------|---------|---------|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP endpoint | `http://localhost:4317` |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Traces-specific endpoint | - |
| `OTEL_EXPORTER_OTLP_HEADERS` | Auth headers (`key=value,...`) | - |
| `OTEL_EXPORTER_OTLP_COMPRESSION` | Compression (`gzip`, `none`) | `none` |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | Export timeout (ms) | `10000` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | Protocol (`grpc`, `http/protobuf`) | `grpc` |

**Batch Processor:**
| Variable | Purpose | Default |
|----------|---------|---------|
| `OTEL_BSP_SCHEDULE_DELAY` | Export interval (ms) | `5000` |
| `OTEL_BSP_EXPORT_TIMEOUT` | Timeout per export (ms) | `30000` |
| `OTEL_BSP_MAX_QUEUE_SIZE` | Max spans in queue | `2048` |
| `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` | Max spans per batch | `512` |

**Attribute Limits:**
| Variable | Purpose | Default |
|----------|---------|---------|
| `OTEL_ATTRIBUTE_COUNT_LIMIT` | Max attributes per span | `128` |
| `OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT` | Max string length | unlimited |
| `OTEL_SPAN_EVENT_COUNT_LIMIT` | Max events per span | `128` |
| `OTEL_SPAN_LINK_COUNT_LIMIT` | Max links per span | `128` |

### Example: Production Configuration

```bash
# Service identity
export OTEL_SERVICE_NAME="shibuya-worker"
export OTEL_RESOURCE_ATTRIBUTES="deployment.environment=production,service.namespace=orders"

# Sampling: 10% of root spans, follow parent decision
export OTEL_TRACES_SAMPLER="parentbased_traceidratio"
export OTEL_TRACES_SAMPLER_ARG="0.1"

# OTLP exporter to Jaeger/Tempo/etc.
export OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4317"
export OTEL_EXPORTER_OTLP_COMPRESSION="gzip"

# Batch processor tuning for high throughput
export OTEL_BSP_MAX_QUEUE_SIZE="4096"
export OTEL_BSP_MAX_EXPORT_BATCH_SIZE="1024"
export OTEL_BSP_SCHEDULE_DELAY="2000"
```

---

## Implementation Phases

### Phase 1: Foundation

**Goal**: Core infrastructure without changing existing behavior

#### 1.1 Add dependencies

```cabal
-- shibuya-core.cabal
build-depends:
  , hs-opentelemetry-api ^>=0.2
  , hs-opentelemetry-sdk ^>=0.1
  , hs-opentelemetry-exporter-otlp ^>=0.1
  , hs-opentelemetry-propagator-w3c ^>=0.1
```

#### 1.2 Create module structure

```
shibuya-core/src/Shibuya/Telemetry/
├── Effect.hs        -- Tracing effect (static dispatch)
├── Config.hs        -- TracingConfig type
├── Propagation.hs   -- W3C context extraction/injection
└── Semantic.hs      -- Semantic conventions (attribute names)
```

#### 1.3 Implement Tracing effect

**File: `Shibuya/Telemetry/Effect.hs`**
```haskell
-- Static effect with Reader pattern
data Tracing :: Effect
type instance DispatchOf Tracing = 'Static 'WithSideEffects
data instance StaticRep Tracing = TracingRep !OTel.Tracer !Bool

runTracing :: (IOE :> es) => OTel.Tracer -> Eff (Tracing : es) a -> Eff es a
runTracingNoop :: (IOE :> es) => Eff (Tracing : es) a -> Eff es a

-- Core operations
withSpan :: (Tracing :> es, IOE :> es) => Text -> SpanArguments -> Eff es a -> Eff es a
withSpan' :: (Tracing :> es, IOE :> es) => Text -> SpanArguments -> (Span -> Eff es a) -> Eff es a
addAttribute :: (Tracing :> es, IOE :> es, ToAttribute a) => Span -> Text -> a -> Eff es ()
addEvent :: (Tracing :> es, IOE :> es) => Span -> NewEvent -> Eff es ()
recordException :: (Tracing :> es, IOE :> es, Exception e) => Span -> e -> Eff es ()
setStatus :: (Tracing :> es, IOE :> es) => Span -> SpanStatus -> Eff es ()
```

#### 1.4 Add traceContext to Envelope

**File: `Shibuya/Core/Ingested.hs`**
```haskell
data Envelope msg = Envelope
  { messageId :: !MessageId
  , cursor :: !(Maybe Cursor)
  , partition :: !(Maybe Text)
  , enqueuedAt :: !(Maybe UTCTime)
  , traceContext :: !(Maybe [(ByteString, ByteString)])  -- NEW
  , payload :: !msg
  }
```

**Deliverables**:
- [ ] Dependencies added to cabal
- [ ] `Shibuya.Telemetry.Effect` module
- [ ] `Shibuya.Telemetry.Config` module
- [ ] `Shibuya.Telemetry.Propagation` module
- [ ] `traceContext` field in Envelope

---

### Phase 2: Instrumentation

**Goal**: Instrument core processing paths

#### 2.1 Semantic conventions

> **Update (2026-04-21):** the attribute-key strings in
> `Shibuya/Telemetry/Semantic.hs` are now derived from the typed
> `AttributeKey` values exported by `OpenTelemetry.SemanticConventions`
> (from `hs-opentelemetry-semantic-conventions`) rather than being
> hand-written. An upstream rename in the conventions library surfaces
> as a Haskell compile error in `Semantic.hs`. Span name follows the
> spec recommendation `<destination> <operation>` — i.e.
> `"<processor-id> process"` — and `messaging.operation=process` is
> always set. See
> [docs/plans/2-align-opentelemetry-semantic-conventions.md](2-align-opentelemetry-semantic-conventions.md)
> for the full rationale and decision log.

**File: `Shibuya/Telemetry/Semantic.hs`**
```haskell
-- Span names
processorSpanName, ingestSpanName, processMessageSpanName :: Text

-- Attribute keys (following OTel semantic conventions)
attrProcessorId, attrMessageId, attrPartition :: Text
attrAckDecision, attrHaltReason :: Text
attrInflightCount, attrInflightMax :: Text

-- Event names
eventMessageReceived, eventProcessingStarted :: Text
eventHandlerCompleted, eventAckDecision :: Text
```

#### 2.2 Instrument Supervised.hs

```haskell
-- processOne gains Tracing constraint
processOne
  :: (IOE :> es, Tracing :> es)
  => TVar ProcessorMetrics
  -> Int
  -> IORef (Maybe HaltReason)
  -> Handler es msg
  -> Ingested es msg
  -> Eff es ()
processOne metricsVar maxConc haltRef handler ingested = do
  let parentCtx = ingested.envelope.traceContext >>= extractTraceContext

  withExtractedContext parentCtx $
    withSpan' "shibuya.process.message" (consumerSpanArgs ingested) $ \span -> do
      -- Add attributes
      addAttribute span "messaging.message.id" ingested.envelope.messageId
      forM_ ingested.envelope.partition $ \p ->
        addAttribute span "messaging.destination.partition" p

      -- Update state, execute handler, finalize
      now <- liftIO getCurrentTime
      updateStateToProcessing metricsVar maxConc now

      addEvent span (mkEvent "handler.started" [])
      result <- try @SomeException $ handler ingested

      case result of
        Left ex -> do
          recordException span ex
          setStatus span (OTel.Error $ T.pack $ show ex)
          -- ... handle exception

        Right decision -> do
          addEvent span $ mkEvent "handler.completed"
            [("ack.decision", toAttribute $ showDecision decision)]

          ingested.ack.finalize decision
          decrementAndUpdate metricsVar decision now

          case decision of
            AckHalt reason -> do
              addEvent span $ mkEvent "halt.requested"
                [("halt.reason", toAttribute reason)]
              setStatus span (OTel.Error reason)
            AckDeadLetter reason ->
              setStatus span (OTel.Error reason)
            _ ->
              setStatus span OTel.Ok
```

#### 2.3 Instrument Ingester.hs

```haskell
runIngesterWithMetrics
  :: (IOE :> es, Tracing :> es)
  => TVar ProcessorMetrics
  -> ProcessorId
  -> Stream (Eff es) (Ingested es msg)
  -> Inbox (Ingested es msg)
  -> Eff es ()
runIngesterWithMetrics metricsVar procId source inbox =
  withSpan "shibuya.ingest" (producerSpanArgs procId) $ do
    Stream.fold Fold.drain $
      Stream.mapM ingestMessage source
  where
    ingestMessage ingested = do
      -- Update metrics
      liftIO $ atomically $ modifyTVar' metricsVar $ \m ->
        m {stats = incReceived m.stats}

      -- Note: We don't create a span per message here (too expensive)
      -- The span is created in processOne with parent context from headers

      liftIO $ send inbox ingested
```

#### 2.4 Update App.hs

```haskell
runApp
  :: (IOE :> es)
  => AppConfig
  -> [QueueProcessor es]
  -> Eff es ()
runApp config processors = do
  if config.tracing.enabled
    then do
      (provider, tracer) <- liftIO $ initTracing config.tracing
      runTracing tracer $ do
        withSpan "shibuya.app" defaultSpanArguments $ do
          runAppInternal config processors
      liftIO $ OTel.shutdownTracerProvider provider
    else
      runTracingNoop $ runAppInternal config processors
```

**Deliverables**:
- [ ] `Shibuya.Telemetry.Semantic` module
- [ ] `processOne` instrumented with spans
- [ ] `runIngesterWithMetrics` instrumented
- [ ] `runApp` initializes tracing
- [ ] Context propagation from message headers

---

### Phase 3: Testing & Polish

**Goal**: Production readiness

#### 3.1 Testing with in-memory exporter

```haskell
-- test/Shibuya/Telemetry/EffectSpec.hs
spec :: Spec
spec = describe "Tracing Effect" $ do
  it "creates spans with correct hierarchy" $ do
    spans <- withInMemoryExporter $ \exporter provider -> do
      let tracer = OTel.makeTracer provider "test" defaultTracerOptions
      runEff $ runTracing tracer $ do
        withSpan "parent" defaultSpanArguments $ do
          withSpan "child" defaultSpanArguments $ do
            pure ()
      getExportedSpans exporter

    length spans `shouldBe` 2
    let [child, parent] = spans
    child.parentSpanId `shouldBe` Just parent.spanId

  it "propagates context from message headers" $ do
    -- Create headers with known trace ID
    let traceId = "0af7651916cd43dd8448eb211c80319c"
        spanId = "b7ad6b7169203331"
        headers = [("traceparent", "00-" <> traceId <> "-" <> spanId <> "-01")]

    spans <- withInMemoryExporter $ \exporter provider -> do
      -- ... test that created span has correct parent
```

#### 3.2 Update shibuya-example

```haskell
-- shibuya-example/Main.hs
main :: IO ()
main = do
  let config = defaultAppConfig
        { tracing = defaultTracingConfig { enabled = True }
        }
  -- Set env vars for local testing:
  -- OTEL_SERVICE_NAME=shibuya-example
  -- OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317

  runEff $ runApp config processors
```

#### 3.3 Docker Compose for local testing

```yaml
# docker-compose.otel.yaml
services:
  jaeger:
    image: jaegertracing/all-in-one:1.50
    ports:
      - "16686:16686"  # UI
      - "4317:4317"    # OTLP gRPC
      - "4318:4318"    # OTLP HTTP

  shibuya-example:
    build: .
    environment:
      OTEL_SERVICE_NAME: shibuya-example
      OTEL_EXPORTER_OTLP_ENDPOINT: http://jaeger:4317
      OTEL_TRACES_SAMPLER: always_on
```

**Deliverables**:
- [ ] Unit tests for Tracing effect
- [ ] Integration tests with in-memory exporter
- [ ] Updated shibuya-example with tracing
- [ ] Docker Compose for local Jaeger testing
- [ ] README section on tracing configuration

---

## Testing Strategy

### In-Memory Exporter Helper

```haskell
-- test/Shibuya/Telemetry/TestUtils.hs
module Shibuya.Telemetry.TestUtils
  ( withInMemoryExporter
  , getExportedSpans
  ) where

import OpenTelemetry.Exporter.InMemory qualified as InMem
import OpenTelemetry.Trace qualified as OTel

withInMemoryExporter
  :: (InMem.InMemorySpanExporter -> OTel.TracerProvider -> IO a)
  -> IO a
withInMemoryExporter action = do
  exporter <- InMem.inMemorySpanExporter
  processor <- OTel.simpleProcessor (InMem.inMemorySpanExporterRef exporter)
  provider <- OTel.createTracerProvider [processor] OTel.emptyTracerProviderOptions
  result <- action exporter provider
  OTel.shutdownTracerProvider provider
  pure result

getExportedSpans :: InMem.InMemorySpanExporter -> IO [OTel.ImmutableSpan]
getExportedSpans = InMem.getFinishedSpans
```

### Unit Tests

```haskell
-- test/Shibuya/Telemetry/EffectSpec.hs
spec :: Spec
spec = describe "Tracing Effect" $ do

  describe "runTracingNoop" $ do
    it "executes actions without creating spans" $ do
      result <- runEff $ runTracingNoop $ do
        withSpan "test" defaultSpanArguments $ do
          pure (42 :: Int)
      result `shouldBe` 42

  describe "runTracing" $ do
    it "creates spans with correct names" $ do
      spans <- withInMemoryExporter $ \_ provider -> do
        let tracer = OTel.makeTracer provider "test" OTel.defaultTracerOptions
        runEff $ runTracing tracer $ do
          withSpan "my-span" defaultSpanArguments $ pure ()
        getExportedSpans exporter

      length spans `shouldBe` 1
      (head spans).spanName `shouldBe` "my-span"

    it "creates correct parent-child relationships" $ do
      spans <- withInMemoryExporter $ \exporter provider -> do
        let tracer = OTel.makeTracer provider "test" OTel.defaultTracerOptions
        runEff $ runTracing tracer $ do
          withSpan "parent" defaultSpanArguments $ do
            withSpan "child" defaultSpanArguments $ do
              pure ()
        getExportedSpans exporter

      length spans `shouldBe` 2
      let [childSpan, parentSpan] = sortOn (.startTime) spans
      childSpan.parentSpanId `shouldBe` Just parentSpan.spanContext.spanId

    it "adds attributes correctly" $ do
      spans <- withInMemoryExporter $ \exporter provider -> do
        let tracer = OTel.makeTracer provider "test" OTel.defaultTracerOptions
        runEff $ runTracing tracer $ do
          withSpan' "test" defaultSpanArguments $ \span -> do
            addAttribute span "key" ("value" :: Text)
            addAttribute span "count" (42 :: Int)
        getExportedSpans exporter

      let span = head spans
      lookupAttribute span.attributes "key" `shouldBe` Just (TextAttribute "value")
      lookupAttribute span.attributes "count" `shouldBe` Just (IntAttribute 42)
```

### Propagation Tests

```haskell
-- test/Shibuya/Telemetry/PropagationSpec.hs
spec :: Spec
spec = describe "Context Propagation" $ do

  it "extracts W3C trace context from headers" $ do
    let headers =
          [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
          , ("tracestate", "congo=t61rcWkgMzE")
          ]
    let Just ctx = extractTraceContext headers

    OTel.traceIdToHex ctx.traceId `shouldBe` "0af7651916cd43dd8448eb211c80319c"
    OTel.spanIdToHex ctx.spanId `shouldBe` "b7ad6b7169203331"
    OTel.isSampled ctx.traceFlags `shouldBe` True

  it "returns Nothing for missing headers" $ do
    extractTraceContext [] `shouldBe` Nothing
    extractTraceContext [("other", "header")] `shouldBe` Nothing

  it "creates child span linked to extracted parent" $ do
    let parentHeaders =
          [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
          ]
        parentCtx = extractTraceContext parentHeaders

    spans <- withInMemoryExporter $ \exporter provider -> do
      let tracer = OTel.makeTracer provider "test" OTel.defaultTracerOptions
      runEff $ runTracing tracer $ do
        withExtractedContext parentCtx $ do
          withSpan "child" (defaultSpanArguments { kind = OTel.Consumer }) $ do
            pure ()
      getExportedSpans exporter

    let childSpan = head spans
    childSpan.parentSpanId `shouldBe` Just (OTel.SpanId "b7ad6b7169203331")
    childSpan.spanContext.traceId `shouldBe` OTel.TraceId "0af7651916cd43dd8448eb211c80319c"
```

### Integration Tests

```haskell
-- test/Shibuya/Telemetry/IntegrationSpec.hs
spec :: Spec
spec = describe "OTel Integration" $ do

  it "traces message processing end-to-end" $ do
    spans <- withInMemoryExporter $ \exporter provider -> do
      let tracer = OTel.makeTracer provider "shibuya" OTel.defaultTracerOptions

      -- Simulate processing a message with trace context
      let msgHeaders =
            [ ("traceparent", "00-abc123def456abc123def456abc12345-1234567890abcdef-01")
            ]
          envelope = Envelope
            { messageId = MessageId "msg-1"
            , traceContext = Just msgHeaders
            , ...
            }

      runEff $ runTracing tracer $ do
        -- This simulates what processOne does
        let parentCtx = envelope.traceContext >>= extractTraceContext
        withExtractedContext parentCtx $ do
          withSpan' "shibuya.process.message" consumerSpanArgs $ \span -> do
            addAttribute span "messaging.message.id" envelope.messageId
            addEvent span (mkEvent "handler.started" [])
            -- simulate handler
            addEvent span (mkEvent "handler.completed" [("ack.decision", "AckOk")])
            setStatus span OTel.Ok

      getExportedSpans exporter

    length spans `shouldBe` 1
    let span = head spans
    span.spanName `shouldBe` "shibuya.process.message"
    span.spanStatus `shouldBe` OTel.Ok
```

### Benchmarks

```haskell
-- bench/TelemetryBench.hs
main :: IO ()
main = defaultMain
  [ bgroup "tracing overhead"
      [ bench "no tracing" $ nfIO $
          runEff $ runTracingNoop $ replicateM_ 1000 processMessage
      , bench "tracing enabled (always_off sampler)" $ nfIO $
          withAlwaysOffSampler $ \tracer ->
            runEff $ runTracing tracer $ replicateM_ 1000 processMessage
      , bench "tracing enabled (10% sampling)" $ nfIO $
          withSampler (OTel.traceIdRatioBased 0.1) $ \tracer ->
            runEff $ runTracing tracer $ replicateM_ 1000 processMessage
      , bench "tracing enabled (100% sampling)" $ nfIO $
          withSampler OTel.alwaysOn $ \tracer ->
            runEff $ runTracing tracer $ replicateM_ 1000 processMessage
      ]
  ]
  where
    processMessage = withSpan "process" defaultSpanArguments $ pure ()
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
      Ingested.hs          # Updated: traceContext field in Envelope
    Telemetry/             # NEW
      Effect.hs            # Tracing effect (static dispatch)
      Config.hs            # TracingConfig type
      Propagation.hs       # W3C context extraction/injection
      Semantic.hs          # Attribute/event name constants
    Runner/
      Supervised.hs        # Updated: processOne instrumented
      Ingester.hs          # Updated: runIngesterWithMetrics instrumented
      Master.hs            # (no changes needed)
    App.hs                 # Updated: tracing initialization
    Prelude.hs             # Re-export Tracing effect

  test/Shibuya/
    Telemetry/
      EffectSpec.hs        # Unit tests for effect
      PropagationSpec.hs   # W3C propagation tests
      IntegrationSpec.hs   # End-to-end tests
      TestUtils.hs         # In-memory exporter helpers

shibuya-example/
  Main.hs                  # Updated: enable tracing
  docker-compose.otel.yaml # Jaeger for local testing

docs/
  guides/
    TELEMETRY.md           # User guide for tracing
```

---

## Dependencies Summary

```cabal
-- shibuya-core.cabal additions
build-depends:
    -- OpenTelemetry
  , hs-opentelemetry-api ^>=0.2
  , hs-opentelemetry-sdk ^>=0.1
  , hs-opentelemetry-exporter-otlp ^>=0.1
  , hs-opentelemetry-propagator-w3c ^>=0.1

-- For testing only
build-depends:
  , hs-opentelemetry-exporter-in-memory ^>=0.1
```

Note: All hs-opentelemetry packages should use compatible versions. Check Hackage for latest versions.

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
