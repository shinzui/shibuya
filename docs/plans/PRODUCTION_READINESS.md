# Production Readiness Plan

## Current State

| Component | Status | Notes |
|-----------|--------|-------|
| Core Framework | ✅ Ready | Serial, Ahead, Async modes working |
| PGMQ Adapter | ✅ Ready | Complete with retries, DLQ, FIFO |
| Metrics/Prometheus | ✅ Ready | Full observability |
| Backpressure | ✅ Ready | Bounded inbox provides rate limiting |
| Health Checks | ✅ Ready | Liveness, readiness, stuck detection, dependency checks |
| Graceful Shutdown | ✅ Ready | Configurable drain timeout, returns drain status |
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
- [x] Add `ShutdownConfig` type
- [x] Implement `stopAppGracefully`
- [x] Add `waitForDrain` helper
- [x] Update `stopApp` to use graceful shutdown by default
- [x] Add tests for graceful shutdown behavior

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
- [x] Create `Metrics/Health.hs` module
- [x] Add `/health/live` endpoint (simple, fast)
- [x] Add `/health/ready` endpoint (checks processor states)
- [x] Add dependency check registration mechanism
- [ ] Add PGMQ adapter dependency check (database ping) - deferred to adapter
- [x] Add "stuck processor" detection (processing for > N seconds)
- [ ] Update documentation - deferred

---

## Phase 3: Load Testing (Hours-Long Endurance)

**Goal**: Verify stability over extended periods with production-like load.

### Approach

Add an executable to existing `shibuya-pgmq-adapter-bench/` that runs for hours:

```haskell
-- shibuya-pgmq-adapter-bench/app/Endurance.hs
main = do
  duration <- fromMaybe 14400 <$> lookupEnv "DURATION_SECS"  -- 4 hours default

  -- Start producer thread (continuous message injection)
  -- Start processor with shibuya-pgmq-adapter
  -- Sample metrics every 30s, write to CSV
  -- At end, check assertions and print summary
```

### Pass/Fail Criteria

| Metric | Threshold |
|--------|-----------|
| Memory growth | < 2x start |
| Failed messages | < 1% |
| P99 latency | < 5 seconds |
| Stuck processors | 0 |

### Tasks
- [ ] Add `executable endurance-test` to existing bench cabal
- [ ] Implement continuous producer loop
- [ ] Add memory sampling via RTS stats (`-T` flag)
- [ ] Write metrics to CSV for post-analysis
- [ ] Print pass/fail summary at end

---

## Phase 4: Chaos Testing

**Goal**: Verify system recovers gracefully from failures.

### Approach

Add chaos scenarios to existing test suite using `tmp-postgres` (already a dependency):

```haskell
-- shibuya-pgmq-adapter/test/Chaos/DatabaseSpec.hs
describe "Chaos: Database disconnect" $ do
  it "recovers after database restart" $ withTmpPostgres $ \pg -> do
    -- Start processing
    -- Kill postgres (pg.stop)
    -- Wait
    -- Restart postgres (pg.start)
    -- Verify processing resumes
```

### Priority Scenarios

| Scenario | Test Method | Expected |
|----------|-------------|----------|
| DB disconnect/reconnect | Stop/start tmp-postgres | Resumes processing |
| Poison message | Insert malformed JSON | Goes to DLQ |
| Long handler | Handler with 60s delay | Lease extended |
| Graceful shutdown | SIGTERM during processing | Drains cleanly |

### Tasks
- [ ] Add `test/Chaos/` directory to pgmq-adapter tests
- [ ] Database disconnect test
- [ ] Poison message test (already partially tested)
- [ ] Long handler lease extension test
- [ ] Graceful shutdown test (after Phase 1)

---

## Phase 5: Documentation & Runbooks

See [docs/operations/](../operations/) for complete documentation.

### Production Deployment Guide
- [x] Kubernetes deployment example (Deployment, Service, PodDisruptionBudget)
- [x] Recommended resource limits (CPU, memory)
- [x] Prometheus scrape configuration
- [x] Alerting rules (processor stuck, high failure rate, memory)

### Runbooks
- [x] Graceful restart procedure
- [x] Scaling up/down
- [x] Handling stuck processors
- [x] Investigating message failures
- [x] Dead letter queue processing

---

## Implementation Order

| Phase | Scope | Estimate | Notes |
|-------|-------|----------|-------|
| 1. Graceful Shutdown | Add drain timeout to `stopApp` | 2 hours | Small change to App.hs |
| 2. Health Checks | Add `/health/live`, `/health/ready` | 2 hours | Extend existing metrics server |
| 3. Load Testing | Extend benchmarks for endurance | 4 hours | Infrastructure exists |
| 4. Chaos Testing | Test harness + scenarios | 4 hours | Scripts with docker-compose |
| 5. Documentation | Runbooks | 2 hours | Can do incrementally |

**Total: ~2 days**

### Why This Is Fast

- Benchmark infrastructure already exists (`shibuya-pgmq-adapter-bench/`)
- Metrics server already exists (`shibuya-metrics/`)
- PGMQ adapter is complete with retries, DLQ, lease extension
- Just extending existing code, not building from scratch

---

## Success Criteria

Before deploying to critical production service:

- [ ] Graceful shutdown drains in-flight messages (< 1% loss)
- [ ] Health checks pass in Kubernetes
- [ ] 4-hour load test passes with stable memory
- [ ] All chaos tests pass (system recovers)
- [ ] Deployment runbook reviewed by team
