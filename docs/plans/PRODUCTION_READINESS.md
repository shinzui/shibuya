# Production Readiness Plan

## Current State

| Component | Status | Notes |
|-----------|--------|-------|
| Core Framework | ✅ Ready | Serial, Ahead, Async modes working |
| PGMQ Adapter | ✅ Ready | Complete with retries, DLQ, FIFO |
| Metrics/Prometheus | ✅ Ready | Full observability |
| Backpressure | ✅ Ready | Bounded inbox provides rate limiting |
| Health Checks | ⚠️ Basic | Needs readiness + dependency checks |
| Graceful Shutdown | ⚠️ Partial | Needs drain period before termination |
| Load Testing | ⚠️ Missing | Need hours-long endurance test |
| Chaos Testing | ⚠️ Missing | Need failure injection tests |
| OpenTelemetry | 🔲 Planned | Not blocking for initial deployment |

---

## Phase 1: Graceful Shutdown

**Goal**: Clean shutdown that drains in-flight messages before termination.

### Current Behavior
```
stopApp → adapter.shutdown → stopMaster → cancel supervisor → cancel children
```
Problem: Children are cancelled immediately, may lose in-flight messages.

### Proposed Behavior
```
stopApp
  ├─ Signal adapters to stop producing (close source streams)
  ├─ Wait for processors to drain (with timeout)
  │   └─ Poll isDone for each processor
  │   └─ Timeout after configurable duration (default 30s)
  ├─ Force stop any remaining processors
  └─ Stop master
```

### Implementation

**File**: `shibuya-core/src/Shibuya/App.hs`

```haskell
data ShutdownConfig = ShutdownConfig
  { drainTimeout :: NominalDiffTime  -- Default: 30 seconds
  }

defaultShutdownConfig :: ShutdownConfig
defaultShutdownConfig = ShutdownConfig { drainTimeout = 30 }

-- New graceful shutdown
stopAppGracefully :: (IOE :> es) => ShutdownConfig -> AppHandle es -> Eff es ()
stopAppGracefully config appHandle = do
  -- 1. Signal adapters to stop producing
  mapM_ shutdownAdapter (Map.elems appHandle.processors)

  -- 2. Wait for drain with timeout
  let deadline = addUTCTime config.drainTimeout <$> getCurrentTime
  drained <- waitForDrain deadline appHandle.processors

  -- 3. Log if forced shutdown
  unless drained $
    -- Log warning: "Forced shutdown, some messages may be lost"
    pure ()

  -- 4. Stop master (cancels any remaining)
  stopMaster appHandle.master

waitForDrain :: UTCTime -> Map ProcessorId (SupervisedProcessor, a) -> Eff es Bool
waitForDrain deadline processors = go
  where
    go = do
      now <- getCurrentTime
      if now >= deadline
        then pure False
        else do
          allDone <- allM isDone (fst <$> Map.elems processors)
          if allDone
            then pure True
            else threadDelay 100000 >> go  -- Check every 100ms
```

### Tasks
- [ ] Add `ShutdownConfig` type
- [ ] Implement `stopAppGracefully`
- [ ] Add `waitForDrain` helper
- [ ] Update `stopApp` to use graceful shutdown by default
- [ ] Add tests for graceful shutdown behavior

---

## Phase 2: Enhanced Health Checks

**Goal**: Kubernetes-compatible liveness and readiness probes with dependency checks.

### Current State
- `GET /health` returns `{"status": "ok", "processorCount": N}`

### Proposed Endpoints

```
GET /health/live    → Am I running? (liveness probe)
GET /health/ready   → Am I ready to receive traffic? (readiness probe)
GET /health         → Detailed health status (for debugging)
```

### Implementation

**File**: `shibuya-metrics/src/Metrics/Health.hs` (new)

```haskell
data LivenessStatus = LivenessStatus
  { alive :: Bool
  }

data ReadinessStatus = ReadinessStatus
  { ready :: Bool
  , processors :: ProcessorReadiness
  , dependencies :: [DependencyStatus]
  }

data ProcessorReadiness = ProcessorReadiness
  { total :: Int
  , healthy :: Int      -- Idle or Processing
  , failed :: Int       -- Failed state
  , stuck :: Int        -- Processing for too long
  }

data DependencyStatus = DependencyStatus
  { name :: Text
  , healthy :: Bool
  , latencyMs :: Maybe Int
  , error :: Maybe Text
  }

-- Liveness: Is the master responding?
checkLiveness :: Master -> IO LivenessStatus
checkLiveness master = do
  -- Try to query metrics with timeout
  result <- timeout 1000000 $ getAllMetricsIO master
  pure $ LivenessStatus { alive = isJust result }

-- Readiness: Are all processors healthy?
checkReadiness :: Master -> [DependencyCheck] -> IO ReadinessStatus
checkReadiness master depChecks = do
  metrics <- getAllMetricsIO master
  let procStatus = analyzeProcessors metrics
  depStatus <- mapM runCheck depChecks
  pure ReadinessStatus
    { ready = procStatus.failed == 0 && all (.healthy) depStatus
    , processors = procStatus
    , dependencies = depStatus
    }

-- Dependency check interface (adapters can register these)
type DependencyCheck = IO DependencyStatus
```

### Tasks
- [ ] Create `Metrics/Health.hs` module
- [ ] Add `/health/live` endpoint (simple, fast)
- [ ] Add `/health/ready` endpoint (checks processor states)
- [ ] Add dependency check registration mechanism
- [ ] Add PGMQ adapter dependency check (database ping)
- [ ] Add "stuck processor" detection (processing for > N seconds)
- [ ] Update documentation

---

## Phase 3: Load Testing (Hours-Long Endurance)

**Goal**: Verify stability over extended periods with production-like load.

### Test Design

```
┌─────────────────────────────────────────────────────────────────┐
│                      LOAD TEST HARNESS                          │
├─────────────────────────────────────────────────────────────────┤
│  Producer (separate process)                                    │
│  ├─ Sends N messages/second to PGMQ                            │
│  ├─ Varies payload sizes (1KB - 100KB)                         │
│  └─ Records send latencies                                      │
├─────────────────────────────────────────────────────────────────┤
│  Shibuya Processor (system under test)                          │
│  ├─ Reads from PGMQ with configurable concurrency              │
│  ├─ Simulates work (configurable delay)                        │
│  ├─ Mix of outcomes: 90% AckOk, 5% AckRetry, 5% exception       │
│  └─ Exposes metrics on :8080                                    │
├─────────────────────────────────────────────────────────────────┤
│  Monitor (prometheus + assertions)                              │
│  ├─ Scrapes metrics every 15s                                  │
│  ├─ Tracks memory usage via RTS stats                          │
│  ├─ Alerts on: memory growth, stuck processors, high failure % │
│  └─ Generates report at end                                     │
└─────────────────────────────────────────────────────────────────┘
```

### Implementation

**Directory**: `shibuya-load-test/`

```
shibuya-load-test/
├── shibuya-load-test.cabal
├── app/
│   ├── Producer.hs      -- Message producer
│   ├── Processor.hs     -- Shibuya processor under test
│   └── Monitor.hs       -- Metrics collector & reporter
├── src/
│   └── LoadTest/
│       ├── Config.hs    -- Test configuration
│       ├── Report.hs    -- Generate HTML/JSON report
│       └── Assertions.hs -- Pass/fail criteria
└── scripts/
    └── run-load-test.sh -- Orchestrates the test
```

### Configuration

```haskell
data LoadTestConfig = LoadTestConfig
  { duration :: NominalDiffTime      -- e.g., 4 hours
  , targetThroughput :: Int          -- messages/second
  , concurrency :: Concurrency       -- Serial, Ahead 5, Async 10
  , handlerDelayMs :: (Int, Int)     -- (min, max) simulated work
  , outcomeDistribution :: OutcomeDistribution
  , payloadSizeBytes :: (Int, Int)   -- (min, max)
  , checkpointIntervalSecs :: Int    -- How often to record stats
  }

data OutcomeDistribution = OutcomeDistribution
  { ackOkPercent :: Int       -- e.g., 90
  , ackRetryPercent :: Int    -- e.g., 5
  , exceptionPercent :: Int   -- e.g., 5
  }
```

### Pass/Fail Criteria

```haskell
data LoadTestResult = LoadTestResult
  { passed :: Bool
  , metrics :: LoadTestMetrics
  , failures :: [AssertionFailure]
  }

data LoadTestMetrics = LoadTestMetrics
  { totalMessages :: Int
  , totalDuration :: NominalDiffTime
  , throughputAvg :: Double           -- msgs/sec
  , throughputP99 :: Double
  , latencyAvgMs :: Double
  , latencyP99Ms :: Double
  , memoryStartMB :: Double
  , memoryEndMB :: Double
  , memoryPeakMB :: Double
  , failedMessages :: Int
  , retriedMessages :: Int
  }

-- Assertions
assertions :: [LoadTestMetrics -> Maybe AssertionFailure]
assertions =
  [ \m -> if m.memoryEndMB > m.memoryStartMB * 2
          then Just "Memory grew more than 2x (possible leak)"
          else Nothing
  , \m -> if m.failedMessages > m.totalMessages `div` 100
          then Just "More than 1% messages failed"
          else Nothing
  , \m -> if m.latencyP99Ms > 5000
          then Just "P99 latency exceeded 5 seconds"
          else Nothing
  ]
```

### Tasks
- [ ] Create `shibuya-load-test` package
- [ ] Implement Producer (uses pgmq-hs directly)
- [ ] Implement Processor (uses shibuya-pgmq-adapter)
- [ ] Implement Monitor (scrapes Prometheus endpoint)
- [ ] Add memory tracking via RTS stats
- [ ] Add report generation (JSON + summary)
- [ ] Create run script with docker-compose for PostgreSQL
- [ ] Document how to run: `./scripts/run-load-test.sh --duration 4h`

---

## Phase 4: Chaos Testing

**Goal**: Verify system recovers gracefully from failures.

### Test Scenarios

| Scenario | Injection | Expected Behavior |
|----------|-----------|-------------------|
| Database disconnect | Kill PostgreSQL | Adapter errors, processor retries on reconnect |
| Database slow | Add latency (tc) | Backpressure kicks in, no OOM |
| Message poison | Send unparseable message | Goes to DLQ, processing continues |
| Handler crash | Random exceptions | Message retried, other handlers unaffected |
| Processor kill | SIGKILL one processor | Other processors continue, supervisor logs |
| Full restart | SIGTERM + restart | Graceful drain, no message loss |
| Memory pressure | Limit to 256MB | OOM killer triggers, clean restart |
| Long handler | Handler takes 5 minutes | Lease extended, no redelivery |

### Implementation

**Directory**: `shibuya-chaos-test/`

```haskell
-- Chaos injection interface
data ChaosAction
  = KillPostgres
  | RestartPostgres
  | AddNetworkLatency Milliseconds
  | RemoveNetworkLatency
  | SendPoisonMessage
  | KillProcessor ProcessorId
  | TriggerOOM
  | PauseProcessor ProcessorId Seconds

-- Test harness
data ChaosTest = ChaosTest
  { name :: Text
  , setup :: IO ChaosEnv
  , injection :: ChaosEnv -> IO ()
  , expectedBehavior :: ChaosEnv -> IO ChaosResult
  , cleanup :: ChaosEnv -> IO ()
  }

runChaosTest :: ChaosTest -> IO TestResult
runChaosTest test = do
  env <- test.setup
  -- Start processor, let it stabilize
  threadDelay 5_000_000
  -- Record baseline metrics
  baseline <- captureMetrics env
  -- Inject chaos
  test.injection env
  -- Wait for system to respond
  threadDelay 10_000_000
  -- Check expected behavior
  result <- test.expectedBehavior env
  -- Cleanup
  test.cleanup env
  pure result
```

### Test: Database Disconnect Recovery

```haskell
databaseDisconnectTest :: ChaosTest
databaseDisconnectTest = ChaosTest
  { name = "Database disconnect and reconnect"
  , setup = do
      pg <- startPostgres
      processor <- startProcessor pg.connectionString
      producer <- startProducer pg.connectionString
      pure ChaosEnv { pg, processor, producer }
  , injection = \env -> do
      -- Record messages processed so far
      beforeCount <- getProcessedCount env.processor
      -- Kill postgres
      stopPostgres env.pg
      -- Wait 30 seconds (system should be failing)
      threadDelay 30_000_000
      -- Restart postgres
      startPostgres env.pg
  , expectedBehavior = \env -> do
      -- Wait for recovery
      threadDelay 10_000_000
      -- Check processor resumed
      afterCount <- getProcessedCount env.processor
      state <- getProcessorState env.processor
      pure $ ChaosResult
        { passed = state == Idle || state == Processing
        , details = "Processed " <> show (afterCount - beforeCount) <> " after recovery"
        }
  , cleanup = \env -> do
      stopProcessor env.processor
      stopPostgres env.pg
  }
```

### Tasks
- [ ] Create `shibuya-chaos-test` package
- [ ] Implement ChaosTest harness
- [ ] Add database disconnect/reconnect test
- [ ] Add poison message test
- [ ] Add handler crash test
- [ ] Add graceful restart test (SIGTERM)
- [ ] Add lease extension test (long handler)
- [ ] Add memory pressure test
- [ ] Document how to run chaos tests
- [ ] Integrate with CI (optional, requires Docker)

---

## Phase 5: Documentation & Runbooks

### Production Deployment Guide
- [ ] Kubernetes deployment example (Deployment, Service, PodDisruptionBudget)
- [ ] Recommended resource limits (CPU, memory)
- [ ] Prometheus scrape configuration
- [ ] Alerting rules (processor stuck, high failure rate, memory)

### Runbooks
- [ ] Graceful restart procedure
- [ ] Scaling up/down
- [ ] Handling stuck processors
- [ ] Investigating message failures
- [ ] Dead letter queue processing

---

## Implementation Order

1. **Phase 1: Graceful Shutdown** (1-2 days)
   - Critical for deployments
   - Prevents message loss

2. **Phase 2: Health Checks** (1 day)
   - Required for Kubernetes
   - Simple implementation

3. **Phase 3: Load Testing** (3-4 days)
   - Builds confidence
   - May reveal issues

4. **Phase 4: Chaos Testing** (3-4 days)
   - Validates recovery
   - Requires more infrastructure

5. **Phase 5: Documentation** (1-2 days)
   - Enables team adoption
   - Can be done incrementally

---

## Success Criteria

Before deploying to critical production service:

- [ ] Graceful shutdown drains in-flight messages (< 1% loss)
- [ ] Health checks pass in Kubernetes
- [ ] 4-hour load test passes with stable memory
- [ ] All chaos tests pass (system recovers)
- [ ] Deployment runbook reviewed by team
