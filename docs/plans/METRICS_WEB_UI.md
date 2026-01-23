# Metrics Web UI Design Options

This document evaluates different approaches for exposing Shibuya metrics through a web UI without affecting processing performance.

## Current State

Metrics are stored in `TVar ProcessorMetrics` per processor, aggregated in `MetricsMap`:

```haskell
data ProcessorMetrics = ProcessorMetrics
  { state     :: ProcessorState   -- Idle | Processing | Failed | Stopped
  , stats     :: StreamStats      -- received, dropped, processed, failed
  , startedAt :: UTCTime
  }

type MetricsMap = Map ProcessorId (TVar ProcessorMetrics)
```

**Key insight:** STM reads are lock-free and O(1). Readers never block writers, so reading metrics has near-zero impact on the processing pipeline.

---

## Option 1: Simple JSON HTTP Endpoint

The simplest approach - add a `/metrics` endpoint that returns JSON.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Application                              │
│                                                                  │
│  ┌─────────────┐         ┌─────────────────────────────────┐   │
│  │  Processors │────────►│  TVar ProcessorMetrics (per)    │   │
│  └─────────────┘  write  └───────────────┬─────────────────┘   │
│                                          │                      │
│                          ┌───────────────▼─────────────────┐   │
│                          │      Warp HTTP Server           │   │
│                          │      (separate thread)          │   │
│                          │                                 │   │
│                          │  GET /metrics → JSON response   │   │
│                          └─────────────────────────────────┘   │
│                                          │                      │
└──────────────────────────────────────────│──────────────────────┘
                                           │
                                           ▼
                                    Browser / curl
                                  (polls periodically)
```

### Implementation Sketch

```haskell
module Shibuya.Metrics.Server
  ( startMetricsServer
  , MetricsServerConfig(..)
  ) where

import Network.Wai (Application, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Network.HTTP.Types (status200, status404)
import Data.Aeson (encode)
import Control.Concurrent (forkIO)
import Control.Concurrent.STM

data MetricsServerConfig = MetricsServerConfig
  { port :: !Int
  , cacheDurationMs :: !Int  -- Optional: cache to reduce serialization
  }

defaultConfig :: MetricsServerConfig
defaultConfig = MetricsServerConfig
  { port = 9090
  , cacheDurationMs = 100
  }

-- | Start metrics server in background thread
startMetricsServer :: MetricsServerConfig -> AppHandle es -> IO ()
startMetricsServer config appHandle = void $ forkIO $ do
  putStrLn $ "Metrics server starting on port " <> show config.port
  Warp.run config.port (metricsApp appHandle)

metricsApp :: AppHandle es -> Application
metricsApp appHandle req respond = case pathInfo req of
  ["metrics"] -> do
    metrics <- getAppMetricsIO appHandle
    respond $ responseLBS status200
      [("Content-Type", "application/json")]
      (encode metrics)

  ["metrics", procId] -> do
    metrics <- getAppMetricsIO appHandle
    case Map.lookup (ProcessorId procId) metrics of
      Just pm -> respond $ responseLBS status200
        [("Content-Type", "application/json")]
        (encode pm)
      Nothing -> respond $ responseLBS status404 [] "Processor not found"

  _ -> respond $ responseLBS status404 [] "Not found"

-- | Read all metrics (STM read is cheap)
getAppMetricsIO :: AppHandle es -> IO (Map ProcessorId ProcessorMetrics)
getAppMetricsIO appHandle = atomically $
  traverse readTVar (appHandle.metricsMap)
```

### API

```
GET /metrics
  → { "orders": { "state": "Processing", "stats": {...} }, ... }

GET /metrics/orders
  → { "state": "Processing", "stats": { "processed": 1234, ... } }
```

### Pros
- Simple to implement (~50 lines)
- No external dependencies beyond `warp`
- Easy to debug with `curl`
- Works with any HTTP client

### Cons
- Polling-based (client must poll for updates)
- No standard format (custom JSON)
- No built-in visualization

### Performance Considerations
- STM read: ~10-50ns per TVar
- JSON serialization: ~1-10μs for typical metrics
- Network: dominates at ~100μs-1ms
- **Impact on processing: effectively zero**

### Optional: Response Caching

To reduce serialization overhead under high request rates:

```haskell
data CachedMetrics = CachedMetrics
  { cachedValue :: !(TVar (Maybe (UTCTime, LBS.ByteString)))
  , cacheDuration :: !NominalDiffTime
  }

getCachedMetrics :: CachedMetrics -> AppHandle es -> IO LBS.ByteString
getCachedMetrics cache appHandle = do
  now <- getCurrentTime
  cached <- readTVarIO cache.cachedValue
  case cached of
    Just (time, value) | diffUTCTime now time < cache.cacheDuration ->
      pure value
    _ -> do
      metrics <- getAppMetricsIO appHandle
      let value = encode metrics
      atomically $ writeTVar cache.cachedValue (Just (now, value))
      pure value
```

---

## Option 2: Prometheus Format

Expose metrics in Prometheus format for integration with Grafana.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Application                              │
│                                                                  │
│  ┌─────────────┐         ┌─────────────────────────────────┐   │
│  │  Processors │────────►│  TVar ProcessorMetrics          │   │
│  └─────────────┘         └───────────────┬─────────────────┘   │
│                                          │                      │
│                          ┌───────────────▼─────────────────┐   │
│                          │   Prometheus Metrics Registry   │   │
│                          │                                 │   │
│                          │  shibuya_processed_total{...}   │   │
│                          │  shibuya_failed_total{...}      │   │
│                          │  shibuya_state{...}             │   │
│                          └───────────────┬─────────────────┘   │
│                                          │                      │
│                          ┌───────────────▼─────────────────┐   │
│                          │      GET /metrics endpoint      │   │
│                          └─────────────────────────────────┘   │
└──────────────────────────────────────────│──────────────────────┘
                                           │
                              ┌────────────▼────────────┐
                              │      Prometheus         │
                              │   (scrapes every 15s)   │
                              └────────────┬────────────┘
                                           │
                              ┌────────────▼────────────┐
                              │        Grafana          │
                              │   (dashboards, alerts)  │
                              └─────────────────────────┘
```

### Implementation Sketch

```haskell
module Shibuya.Metrics.Prometheus
  ( PrometheusMetrics
  , setupPrometheus
  , updatePrometheusMetrics
  , prometheusMiddleware
  ) where

import Prometheus qualified as P
import Prometheus.Metric.GHC (ghcMetrics)

data PrometheusMetrics = PrometheusMetrics
  { processedTotal :: P.Vector P.Label1 P.Counter
  , failedTotal    :: P.Vector P.Label1 P.Counter
  , receivedTotal  :: P.Vector P.Label1 P.Counter
  , processorState :: P.Vector P.Label1 P.Gauge
  , processingTime :: P.Vector P.Label1 P.Histogram
  }

setupPrometheus :: IO PrometheusMetrics
setupPrometheus = do
  processed <- P.register $ P.vector "processor_id" $ P.counter
    P.Info
      { P.metricName = "shibuya_messages_processed_total"
      , P.metricHelp = "Total messages processed successfully"
      }

  failed <- P.register $ P.vector "processor_id" $ P.counter
    P.Info
      { P.metricName = "shibuya_messages_failed_total"
      , P.metricHelp = "Total messages that failed processing"
      }

  received <- P.register $ P.vector "processor_id" $ P.counter
    P.Info
      { P.metricName = "shibuya_messages_received_total"
      , P.metricHelp = "Total messages received from queue"
      }

  state <- P.register $ P.vector "processor_id" $ P.gauge
    P.Info
      { P.metricName = "shibuya_processor_state"
      , P.metricHelp = "Processor state (0=idle, 1=processing, 2=failed, 3=stopped)"
      }

  processingTime <- P.register $ P.vector "processor_id" $ P.histogram
    P.Info
      { P.metricName = "shibuya_message_processing_seconds"
      , P.metricHelp = "Message processing duration"
      }
    P.defaultBuckets

  -- Optionally include GHC runtime metrics
  _ <- P.register ghcMetrics

  pure PrometheusMetrics
    { processedTotal = processed
    , failedTotal = failed
    , receivedTotal = received
    , processorState = state
    , processingTime = processingTime
    }

-- | Sync Shibuya metrics to Prometheus (call periodically or on change)
updatePrometheusMetrics :: PrometheusMetrics -> MetricsMap -> IO ()
updatePrometheusMetrics prom metricsMap = do
  forM_ (Map.toList metricsMap) $ \(ProcessorId pid, tvar) -> do
    pm <- readTVarIO tvar
    let label = pid

    -- Update counters (Prometheus counters only go up, so we set absolute values)
    P.withLabel prom.processedTotal label $ \c ->
      P.setToCurrentCount c (fromIntegral pm.stats.processed)

    P.withLabel prom.failedTotal label $ \c ->
      P.setToCurrentCount c (fromIntegral pm.stats.failed)

    P.withLabel prom.receivedTotal label $ \c ->
      P.setToCurrentCount c (fromIntegral pm.stats.received)

    -- Update state gauge
    P.withLabel prom.processorState label $ \g ->
      P.setGauge g (stateToDouble pm.state)

stateToDouble :: ProcessorState -> Double
stateToDouble = \case
  Idle -> 0
  Processing _ _ -> 1
  Failed _ _ -> 2
  Stopped -> 3

-- | WAI middleware that serves /metrics
prometheusMiddleware :: P.PrometheusSettings -> Middleware
prometheusMiddleware = P.prometheus
```

### Prometheus Output Format

```
# HELP shibuya_messages_processed_total Total messages processed successfully
# TYPE shibuya_messages_processed_total counter
shibuya_messages_processed_total{processor_id="orders"} 12345
shibuya_messages_processed_total{processor_id="events"} 67890

# HELP shibuya_messages_failed_total Total messages that failed processing
# TYPE shibuya_messages_failed_total counter
shibuya_messages_failed_total{processor_id="orders"} 23
shibuya_messages_failed_total{processor_id="events"} 5

# HELP shibuya_processor_state Processor state (0=idle, 1=processing, 2=failed, 3=stopped)
# TYPE shibuya_processor_state gauge
shibuya_processor_state{processor_id="orders"} 1
shibuya_processor_state{processor_id="events"} 0

# HELP shibuya_message_processing_seconds Message processing duration
# TYPE shibuya_message_processing_seconds histogram
shibuya_message_processing_seconds_bucket{processor_id="orders",le="0.005"} 4523
shibuya_message_processing_seconds_bucket{processor_id="orders",le="0.01"} 8934
...
```

### Grafana Dashboard Queries

```promql
# Processing rate (messages/second)
rate(shibuya_messages_processed_total[5m])

# Error rate
rate(shibuya_messages_failed_total[5m]) / rate(shibuya_messages_received_total[5m])

# Processing latency p99
histogram_quantile(0.99, rate(shibuya_message_processing_seconds_bucket[5m]))

# Processors currently processing
sum(shibuya_processor_state == 1)
```

### Pros
- Industry standard format
- Rich ecosystem (Grafana, AlertManager)
- Built-in histograms for latency percentiles
- Pull-based (Prometheus controls scrape rate)
- Easy alerting integration

### Cons
- Requires Prometheus + Grafana infrastructure
- More complex setup
- Additional dependency (`prometheus-client`)
- Counter semantics can be tricky (monotonic only)

### Performance Considerations
- Prometheus scrapes every 15-60s typically
- Metric updates are atomic counter increments
- **Impact on processing: negligible**

### Dependencies

```cabal
build-depends:
    prometheus-client >= 1.1
  , prometheus-metrics-ghc >= 1.0  -- Optional: GHC runtime metrics
  , wai-middleware-prometheus >= 1.0
```

---

## Option 3: Server-Sent Events (SSE)

Real-time streaming updates to the browser using SSE.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Application                              │
│                                                                  │
│  ┌─────────────┐         ┌─────────────────────────────────┐   │
│  │  Processors │────────►│  TVar ProcessorMetrics          │   │
│  └─────────────┘  write  └───────────────┬─────────────────┘   │
│                                          │                      │
│                          ┌───────────────▼─────────────────┐   │
│                          │      SSE Stream Generator       │   │
│                          │                                 │   │
│                          │  STM retry waits for changes    │   │
│                          │  Only sends on actual updates   │   │
│                          └───────────────┬─────────────────┘   │
│                                          │                      │
│                          ┌───────────────▼─────────────────┐   │
│                          │      Warp HTTP Server           │   │
│                          │      Content-Type: text/event   │   │
│                          └─────────────────────────────────┘   │
└──────────────────────────────────────────│──────────────────────┘
                                           │
                              ┌────────────▼────────────┐
                              │        Browser          │
                              │    EventSource API      │
                              │                         │
                              │  const es = new         │
                              │    EventSource(url);    │
                              │  es.onmessage = ...     │
                              └─────────────────────────┘
```

### Implementation Sketch

```haskell
module Shibuya.Metrics.SSE
  ( startSSEServer
  , metricsEventStream
  ) where

import Network.Wai (Application, responseStream)
import Network.Wai.Handler.Warp qualified as Warp
import Network.HTTP.Types (status200)
import Data.Aeson (encode)
import Control.Concurrent.STM
import Streamly.Data.Stream qualified as Stream

-- | SSE event format
data SSEEvent = SSEEvent
  { eventType :: Maybe Text
  , eventData :: LBS.ByteString
  }

formatSSE :: SSEEvent -> Builder
formatSSE event = mconcat
  [ maybe mempty (\t -> "event: " <> byteString (encodeUtf8 t) <> "\n") event.eventType
  , "data: " <> lazyByteString event.eventData <> "\n\n"
  ]

-- | Stream that emits only when metrics change
metricsEventStream :: MetricsMap -> Stream IO SSEEvent
metricsEventStream metricsMap = Stream.unfoldrM go Nothing
  where
    go :: Maybe (Map ProcessorId ProcessorMetrics) -> IO (Maybe (SSEEvent, Maybe (Map ProcessorId ProcessorMetrics)))
    go lastMetrics = do
      -- Wait for metrics to differ from last snapshot
      currentMetrics <- atomically $ do
        current <- traverse readTVar metricsMap
        case lastMetrics of
          Nothing -> pure current  -- First read, don't wait
          Just last -> do
            when (current == last) retry  -- Block until changed
            pure current

      let event = SSEEvent
            { eventType = Just "metrics"
            , eventData = encode currentMetrics
            }

      pure $ Just (event, Just currentMetrics)

-- | WAI application for SSE endpoint
sseApp :: MetricsMap -> Application
sseApp metricsMap req respond = case pathInfo req of
  ["events", "metrics"] ->
    respond $ responseStream status200
      [ ("Content-Type", "text/event-stream")
      , ("Cache-Control", "no-cache")
      , ("Connection", "keep-alive")
      ] $ \write flush -> do
        -- Send initial metrics immediately
        initialMetrics <- atomically $ traverse readTVar metricsMap
        write $ formatSSE SSEEvent
          { eventType = Just "metrics"
          , eventData = encode initialMetrics
          }
        flush

        -- Stream updates as they happen
        Stream.fold (Fold.drainMapM (sendEvent write flush))
          (metricsEventStream metricsMap)

  -- Serve a simple HTML dashboard
  ["dashboard"] ->
    respond $ responseLBS status200
      [("Content-Type", "text/html")]
      dashboardHtml

  _ -> respond $ responseLBS status404 [] "Not found"
  where
    sendEvent write flush event = do
      write (formatSSE event)
      flush

startSSEServer :: Int -> MetricsMap -> IO ()
startSSEServer port metricsMap = do
  putStrLn $ "SSE metrics server on port " <> show port
  Warp.run port (sseApp metricsMap)
```

### Client-Side JavaScript

```html
<!DOCTYPE html>
<html>
<head>
  <title>Shibuya Metrics</title>
  <style>
    .processor { border: 1px solid #ccc; margin: 10px; padding: 10px; }
    .idle { background: #e8f5e9; }
    .processing { background: #fff3e0; }
    .failed { background: #ffebee; }
  </style>
</head>
<body>
  <h1>Shibuya Processors</h1>
  <div id="processors"></div>

  <script>
    const es = new EventSource('/events/metrics');

    es.addEventListener('metrics', (event) => {
      const metrics = JSON.parse(event.data);
      const container = document.getElementById('processors');

      container.innerHTML = Object.entries(metrics)
        .map(([id, m]) => `
          <div class="processor ${m.state.tag.toLowerCase()}">
            <h3>${id}</h3>
            <p>State: ${m.state.tag}</p>
            <p>Processed: ${m.stats.processed}</p>
            <p>Failed: ${m.stats.failed}</p>
            <p>Received: ${m.stats.received}</p>
          </div>
        `).join('');
    });

    es.onerror = () => {
      console.log('SSE connection lost, reconnecting...');
    };
  </script>
</body>
</html>
```

### Pros
- Real-time updates (no polling delay)
- Efficient (only sends when data changes)
- Simple browser API (`EventSource`)
- Auto-reconnect built into browser
- Works through proxies/firewalls (HTTP)

### Cons
- One-directional (server → client only)
- Connection per client (scalability limit ~1000s of connections)
- No built-in visualization (need custom UI)
- SSE not supported in some old browsers

### Performance Considerations
- **STM retry is efficient** - thread sleeps until TVar changes
- No CPU usage while waiting for changes
- One thread per connected client
- **Impact on processing: effectively zero**

### Rate Limiting Option

If metrics change too frequently, add throttling:

```haskell
-- Emit at most every 100ms
throttledStream :: MetricsMap -> Stream IO SSEEvent
throttledStream metricsMap =
  Stream.catMaybes $
    Stream.zipWith combine
      (metricsEventStream metricsMap)
      (Stream.repeatM (threadDelay 100_000 >> pure ()))
  where
    combine event () = Just event
```

---

## Option 4: WebSocket (Bidirectional)

Full bidirectional communication for interactive dashboards.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Application                              │
│                                                                  │
│  ┌─────────────┐         ┌─────────────────────────────────┐   │
│  │  Processors │────────►│  TVar ProcessorMetrics          │   │
│  └─────────────┘         └───────────────┬─────────────────┘   │
│                                          │                      │
│                          ┌───────────────▼─────────────────┐   │
│                          │      WebSocket Handler          │   │
│                          │                                 │   │
│                          │  ◄── subscribe/unsubscribe     │   │
│                          │  ──► metrics updates            │   │
│                          │  ◄── commands (future)          │   │
│                          └───────────────┬─────────────────┘   │
│                                          │                      │
│                          ┌───────────────▼─────────────────┐   │
│                          │      Warp + WebSockets          │   │
│                          └─────────────────────────────────┘   │
└──────────────────────────────────────────│──────────────────────┘
                                           │
                              ┌────────────▼────────────┐
                              │        Browser          │
                              │    WebSocket API        │
                              │                         │
                              │  const ws = new         │
                              │    WebSocket(url);      │
                              └─────────────────────────┘
```

### Implementation Sketch

```haskell
module Shibuya.Metrics.WebSocket
  ( startWebSocketServer
  ) where

import Network.WebSockets qualified as WS
import Network.Wai.Handler.WebSockets (websocketsOr)
import Data.Aeson (encode, decode)

-- | Messages from client to server
data ClientMessage
  = Subscribe [ProcessorId]    -- Subscribe to specific processors
  | SubscribeAll               -- Subscribe to all processors
  | Unsubscribe [ProcessorId]
  | Ping
  deriving (Generic, FromJSON)

-- | Messages from server to client
data ServerMessage
  = MetricsUpdate (Map ProcessorId ProcessorMetrics)
  | ProcessorUpdate ProcessorId ProcessorMetrics
  | Pong
  | Error Text
  deriving (Generic, ToJSON)

-- | Per-connection state
data ClientState = ClientState
  { subscriptions :: TVar (Set ProcessorId)
  , sendQueue :: TBQueue ServerMessage
  }

wsApp :: MetricsMap -> WS.ServerApp
wsApp metricsMap pending = do
  conn <- WS.acceptRequest pending
  WS.withPingThread conn 30 (pure ()) $ do
    -- Initialize client state
    subsVar <- newTVarIO Set.empty
    sendQueue <- newTBQueueIO 100

    let clientState = ClientState subsVar sendQueue

    -- Sender thread: forwards messages from queue to WebSocket
    withAsync (sender conn sendQueue) $ \_ ->
      -- Updater thread: watches TVars and queues updates
      withAsync (updater metricsMap clientState) $ \_ ->
        -- Receiver: handles incoming messages
        receiver conn metricsMap clientState

receiver :: WS.Connection -> MetricsMap -> ClientState -> IO ()
receiver conn metricsMap state = forever $ do
  msg <- WS.receiveData conn
  case decode msg of
    Just SubscribeAll -> do
      let allIds = Set.fromList $ Map.keys metricsMap
      atomically $ writeTVar state.subscriptions allIds
      -- Send initial state
      metrics <- atomically $ traverse readTVar metricsMap
      atomically $ writeTBQueue state.sendQueue (MetricsUpdate metrics)

    Just (Subscribe ids) -> do
      atomically $ modifyTVar' state.subscriptions (<> Set.fromList ids)

    Just (Unsubscribe ids) -> do
      atomically $ modifyTVar' state.subscriptions (Set.\\ Set.fromList ids)

    Just Ping ->
      atomically $ writeTBQueue state.sendQueue Pong

    Nothing ->
      atomically $ writeTBQueue state.sendQueue (Error "Invalid message")

sender :: WS.Connection -> TBQueue ServerMessage -> IO ()
sender conn queue = forever $ do
  msg <- atomically $ readTBQueue queue
  WS.sendTextData conn (encode msg)

updater :: MetricsMap -> ClientState -> IO ()
updater metricsMap state = go Map.empty
  where
    go lastMetrics = do
      -- Wait for any subscribed processor to change
      (changedId, newValue) <- atomically $ do
        subs <- readTVar state.subscriptions
        if Set.null subs
          then retry  -- No subscriptions, wait
          else do
            -- Check each subscribed processor for changes
            changes <- forM (Set.toList subs) $ \pid ->
              case Map.lookup pid metricsMap of
                Nothing -> pure Nothing
                Just tvar -> do
                  current <- readTVar tvar
                  let changed = Map.lookup pid lastMetrics /= Just current
                  pure $ if changed then Just (pid, current) else Nothing

            case catMaybes changes of
              [] -> retry  -- No changes, wait
              ((pid, val):_) -> pure (pid, val)

      -- Send update
      atomically $ writeTBQueue state.sendQueue (ProcessorUpdate changedId newValue)

      -- Continue with updated snapshot
      go (Map.insert changedId newValue lastMetrics)

startWebSocketServer :: Int -> MetricsMap -> IO ()
startWebSocketServer port metricsMap = do
  putStrLn $ "WebSocket metrics server on port " <> show port
  Warp.run port $ websocketsOr WS.defaultConnectionOptions
    (wsApp metricsMap)
    fallbackApp
  where
    fallbackApp _ respond = respond $ responseLBS status400 [] "WebSocket only"
```

### Client-Side JavaScript

```javascript
const ws = new WebSocket('ws://localhost:9090');

ws.onopen = () => {
  // Subscribe to all processors
  ws.send(JSON.stringify({ tag: 'SubscribeAll' }));
};

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);

  switch (msg.tag) {
    case 'MetricsUpdate':
      // Full update of all metrics
      updateDashboard(msg.contents);
      break;

    case 'ProcessorUpdate':
      // Single processor update
      const [processorId, metrics] = msg.contents;
      updateProcessor(processorId, metrics);
      break;

    case 'Pong':
      console.log('Pong received');
      break;

    case 'Error':
      console.error('Server error:', msg.contents);
      break;
  }
};

// Heartbeat
setInterval(() => {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify({ tag: 'Ping' }));
  }
}, 30000);
```

### Pros
- Bidirectional (can send commands in future)
- Efficient (only sends changes for subscribed processors)
- Low latency
- Can implement selective subscriptions
- Future extensibility (pause/resume, control commands)

### Cons
- More complex implementation
- Requires connection management
- WebSocket support needed in infrastructure (some proxies struggle)
- More client-side code needed

### Performance Considerations
- One thread per client (receiver + sender + updater)
- TBQueue bounds memory per client
- STM retry efficient for change detection
- **Impact on processing: negligible**

### Dependencies

```cabal
build-depends:
    websockets >= 0.12
  , wai-websockets >= 3.0
```

---

## Option 5: Hybrid Approach (Recommended)

Combine Prometheus for operational monitoring with SSE/WebSocket for live dashboards.

### Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Application                                     │
│                                                                              │
│  ┌─────────────┐              ┌─────────────────────────────────┐          │
│  │  Processors │─────────────►│  TVar ProcessorMetrics          │          │
│  └─────────────┘              └───────────────┬─────────────────┘          │
│                                               │                             │
│                    ┌──────────────────────────┼──────────────────────────┐ │
│                    │                          │                          │ │
│        ┌───────────▼───────────┐  ┌──────────▼──────────┐               │ │
│        │   Prometheus Export   │  │    SSE/WebSocket    │               │ │
│        │   GET /metrics        │  │    GET /events      │               │ │
│        │   (port 9090)         │  │    (port 9091)      │               │ │
│        └───────────┬───────────┘  └──────────┬──────────┘               │ │
│                    │                          │                          │ │
└────────────────────│──────────────────────────│──────────────────────────┘ │
                     │                          │                             │
        ┌────────────▼────────────┐  ┌─────────▼──────────┐                  │
        │      Prometheus         │  │      Browser       │                  │
        │      + Grafana          │  │   (Live Dashboard) │                  │
        │   (Ops monitoring)      │  │   (Dev/debugging)  │                  │
        └─────────────────────────┘  └────────────────────┘                  │
```

### Use Cases

| Component | Use Case |
|-----------|----------|
| Prometheus + Grafana | Production monitoring, alerting, historical data |
| SSE/WebSocket | Developer debugging, live demos, real-time dashboard |
| JSON endpoint | Simple integrations, health checks, scripts |

### Implementation

```haskell
module Shibuya.Metrics.Server
  ( MetricsConfig(..)
  , defaultMetricsConfig
  , startMetricsServer
  ) where

data MetricsConfig = MetricsConfig
  { jsonPort :: Maybe Int           -- Simple JSON endpoint
  , prometheusPort :: Maybe Int     -- Prometheus metrics
  , ssePort :: Maybe Int            -- Server-Sent Events
  , wsPort :: Maybe Int             -- WebSocket
  }

defaultMetricsConfig :: MetricsConfig
defaultMetricsConfig = MetricsConfig
  { jsonPort = Just 9090
  , prometheusPort = Just 9091
  , ssePort = Nothing              -- Opt-in for real-time
  , wsPort = Nothing
  }

startMetricsServer :: MetricsConfig -> AppHandle es -> IO ()
startMetricsServer config appHandle = do
  -- Start enabled servers
  forM_ config.jsonPort $ \port ->
    forkIO $ startJSONServer port appHandle

  forM_ config.prometheusPort $ \port ->
    forkIO $ startPrometheusServer port appHandle

  forM_ config.ssePort $ \port ->
    forkIO $ startSSEServer port appHandle

  forM_ config.wsPort $ \port ->
    forkIO $ startWebSocketServer port appHandle
```

---

## Comparison Matrix

| Aspect | JSON Endpoint | Prometheus | SSE | WebSocket |
|--------|---------------|------------|-----|-----------|
| **Complexity** | Low | Medium | Medium | High |
| **Real-time** | No (polling) | No (15-60s) | Yes | Yes |
| **Bidirectional** | No | No | No | Yes |
| **Infrastructure** | None | Prometheus+Grafana | None | None |
| **Visualization** | Custom | Grafana | Custom | Custom |
| **Alerting** | Custom | AlertManager | Custom | Custom |
| **Historical data** | No | Yes | No | No |
| **Scalability** | High | High | ~1000 clients | ~1000 clients |
| **Browser support** | Any | N/A | Modern | Modern |
| **Dependencies** | warp | prometheus-client | warp | websockets |

---

## Performance Impact Summary

All approaches have **negligible impact** on the processing pipeline:

1. **STM reads are O(1) and lock-free** - readers never block writers
2. **Metrics servers run in separate threads** - no contention with processors
3. **Efficient change detection** - SSE/WebSocket use STM retry (no polling)
4. **Serialization happens outside the hot path** - only when serving requests

### Benchmarks (approximate)

| Operation | Time |
|-----------|------|
| STM read (TVar) | 10-50 ns |
| JSON serialization (10 processors) | 1-5 μs |
| HTTP response (local) | 50-200 μs |
| STM retry wake-up | < 1 μs |

The processing pipeline does millions of STM writes; a few reads from the metrics server are imperceptible.

---

## Recommendations

### For Production
**Use Prometheus + Grafana** (Option 2)
- Standard tooling, proven at scale
- Alerting integration
- Historical queries

### For Development/Debugging
**Add SSE endpoint** (Option 3)
- Real-time feedback
- Simple browser integration
- No external dependencies

### For Quick Start
**Start with JSON endpoint** (Option 1)
- Minimal code
- Easy to extend later
- Works with curl/scripts

### Future Extensibility
**Design for WebSocket** (Option 4)
- If you anticipate control commands (pause/resume processors)
- If you need selective subscriptions
- If building a rich interactive dashboard

---

## Next Steps

1. **Choose initial approach** - Recommend Option 1 (JSON) + Option 2 (Prometheus)
2. **Define metrics schema** - What additional metrics beyond current?
3. **Design API contract** - Endpoint paths, JSON structure, versioning
4. **Consider authentication** - Should metrics endpoints be protected?
5. **Plan dashboard** - Grafana? Custom? Both?
