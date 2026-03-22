# Shibuya vs Broadway: Feature Comparison & Improvement Roadmap

A comprehensive comparison between **Shibuya** (Haskell) and **Broadway** (Elixir), with actionable suggestions for bringing Shibuya to feature parity and beyond.

---

## Feature Matrix

| Feature | Broadway (Elixir) | Shibuya (Haskell) | Gap |
|---------|-------------------|-------------------|-----|
| **Core Pipeline** | Producer → Processor → Batcher → BatchProcessor → Ack | Adapter → Ingester → Processor → Ack | Batching stage missing |
| **Backpressure** | GenStage demand-driven (min/max demand per stage) | Bounded inbox (blocks when full) | Comparable (different mechanisms) |
| **Concurrency** | Per-stage concurrency count | Serial / Ahead N / Async N | Comparable |
| **Supervision** | Multi-level OTP supervision tree | NQE Master + Supervisor | Broadway more granular |
| **Batching** | First-class: batch_size, batch_timeout, batch_key, dynamic sizing | Not built-in | **Major gap** |
| **Rate Limiting** | Built-in, runtime-adjustable | Not built-in | **Major gap** |
| **Partitioning** | `partition_by` at every stage, hash-based dispatch | `PartitionedInOrder` policy (documented, not enforced) | **Major gap** |
| **Telemetry** | `:telemetry` events at every pipeline stage | OpenTelemetry tracing + custom metrics | Different approach, both good |
| **Graceful Shutdown** | Drain producers → flush batchers → ack → timeout | Signal adapters → drain inbox → timeout | Comparable |
| **Testing** | `test_message/3`, `test_batch/3`, `DummyProducer`, `CallerAcknowledger` | `listAdapter`, `TrackingAck` | Broadway richer |
| **Ack Semantics** | Acknowledger behaviour, `ack_immediately`, `configure_ack` | AckDecision (Ok/Retry/DeadLetter/Halt) | Shibuya more expressive |
| **Error Handling** | `handle_failed/2` callback, per-message failure | Exception → Failed state, AckHalt | Broadway more granular |
| **Message Transform** | Transformer stage (convert raw events → Messages) | Adapter responsibility | Broadway more composable |
| **Multiple Producers** | Yes, N concurrent producers per pipeline | One adapter per processor | **Gap** |
| **Push Messages** | `push_messages/2` for injecting out-of-band | Not supported | Minor gap |
| **Restart Semantics** | one_for_one (producers), one_for_all (processors) | IgnoreFailures / StopAllOnFailure | Broadway more nuanced |
| **Dynamic Config** | Runtime rate limit updates, `:ets` storage | Static configuration | **Gap** |
| **Topology Introspection** | `topology/1`, `all_running/0`, `producer_names/1` | `getAppMetrics`, `getAppMaster` | Comparable |
| **Halt Semantics** | Not built-in (retry/fail only) | AckHalt with graceful isolation | **Shibuya advantage** |
| **Lease Extension** | Not built-in (adapter responsibility) | First-class `Lease` type | **Shibuya advantage** |
| **Effect System** | OTP processes (implicit side effects) | effectful (typed effect constraints) | **Shibuya advantage** |
| **Prepare Messages** | `prepare_messages/2` (batch preprocessing) | Not built-in | Gap |

---

## Detailed Comparison

### 1. Pipeline Architecture

**Broadway** has a 4-stage pipeline:
```
Producers (N) → Processors (N) → Batchers (per key) → BatchProcessors (N) → Ack
```
Each stage is a GenStage process with demand-driven backpressure. Messages flow through every stage, and batchers accumulate messages before handing them off in groups.

**Shibuya** has a 2-stage pipeline:
```
Adapter.source (stream) → Ingester (async, bounded inbox) → Processor → Ack
```
The adapter produces a Streamly stream, the ingester buffers into a bounded inbox, and the processor handles messages one at a time.

**Key Difference:** Broadway's batching stage is integral to its architecture—many real-world use cases (database inserts, API calls, S3 uploads) benefit enormously from batching. Shibuya processes messages individually.

### 2. Backpressure

**Broadway:** Fine-grained, per-stage. Each GenStage consumer specifies `min_demand` and `max_demand`. Producers only emit when they receive demand. This creates natural flow control across every boundary in the pipeline.

**Shibuya:** Binary—bounded inbox blocks when full. Effective but coarser. No per-stage tuning knobs.

**Assessment:** Both work, but Broadway's demand-driven model is more idiomatic for multi-stage pipelines and gives operators more tuning levers.

### 3. Batching

**Broadway:** First-class concept with rich configuration:
- `batch_size` — integer or custom accumulator function
- `batch_timeout` — flush after N ms even if batch isn't full
- `batch_key` — route messages to different batch groups
- Multiple batchers per pipeline
- `handle_batch/4` callback processes entire batch
- `:flush` batch mode for immediate emission

**Shibuya:** No batching stage. Handlers process one message at a time. Batching would need to be implemented in user-space (e.g., accumulating in handler state).

### 4. Rate Limiting

**Broadway:** Built-in, configurable per producer:
```elixir
rate_limiting: [allowed_messages: 2000, interval: 1000]
```
Runtime-adjustable via `update_rate_limiting/2`. Uses atomic counters for efficiency.

**Shibuya:** Not built-in. Backpressure from bounded inbox provides implicit throttling, but there's no explicit rate control.

### 5. Partitioning

**Broadway:** Hash-based `partition_by` function at every stage:
```elixir
partition_by: fn msg -> :erlang.phash2(msg.data.user_id) end
```
Messages with the same partition always go to the same stage instance, guaranteeing per-partition ordering with cross-partition concurrency.

**Shibuya:** `PartitionedInOrder` policy documents the contract but doesn't enforce it. The framework doesn't route messages by partition key—this is left to the adapter.

### 6. Supervision & Fault Tolerance

**Broadway:** Multi-level OTP supervision tree with different strategies per level:
- Producers: `one_for_one` — individual restart, others unaffected
- Processors: `one_for_all` — all restart together (consistent state)
- Batchers: `rest_for_one` — batcher failure cascades to its batch processors
- Auto-resubscribe to producers after crash

**Shibuya:** Two strategies:
- `IgnoreFailures` — failed processors stay failed, others continue
- `StopAllOnFailure` — one failure stops everything

No individual processor restart. No resubscription on failure.

### 7. Error Handling

**Broadway:**
- Exceptions in `handle_message` mark the message as failed (pipeline continues)
- `handle_failed/2` callback for custom failure logic
- Failed messages still get acknowledged (as failed)
- Batch-level failures mark entire batch

**Shibuya:**
- Exceptions set processor state to `Failed`
- `AckHalt` gracefully stops the processor
- `AckRetry` and `AckDeadLetter` are explicit decisions
- No callback hook for failed messages

### 8. Testing

**Broadway:**
- `test_message/3` — inject single message, receive ack notification
- `test_batch/3` — inject batch, respects pipeline batching config
- `DummyProducer` — placeholder producer for tests
- `CallerAcknowledger` — sends ack messages to test process
- Ecto sandbox integration for concurrent DB tests

**Shibuya:**
- `listAdapter` — create adapter from a list of messages
- `TrackingAck` — record all ack decisions for assertions
- Metrics introspection in tests

---

## Shibuya's Advantages Over Broadway

Shibuya isn't just playing catch-up—it has genuine strengths:

1. **Typed Effect System (effectful)** — Handler effects are tracked in types. You know at compile time what effects a handler can perform. Broadway relies on runtime process isolation.

2. **AckHalt Semantics** — Broadway has no concept of a handler signaling "stop processing this queue." Shibuya's `AckHalt` with halt isolation is a clean pattern for poison messages.

3. **First-class Lease Extension** — `Lease` type allows handlers to extend visibility timeouts during long processing. In Broadway, this is entirely the producer's responsibility.

4. **Explicit Ack Intent** — `AckDecision` (`Ok | Retry delay | DeadLetter reason | Halt reason`) makes acknowledgment intent clear and composable. Broadway's acknowledger pattern is more flexible but less structured.

5. **Streamly-based Streaming** — Streamly's fusion optimization can eliminate intermediate allocations. Broadway's GenStage is process-per-stage, adding message-passing overhead.

6. **Concurrency Modes** — `Ahead N` (ordered concurrent prefetch) is unique. Broadway's `partition_by` solves a related problem but doesn't offer prefetch-with-reorder.

---

## Improvement Roadmap

Prioritized by impact and feasibility.

### Priority 1: First-Class Batching (High Impact, Medium Effort)

**What:** Add a batching stage between processor and ack.

**Design sketch:**
```haskell
data BatchConfig msg = BatchConfig
  { batchSize    :: Int              -- max messages per batch
  , batchTimeout :: NominalDiffTime  -- flush after timeout
  , batchKey     :: msg -> Text      -- group messages by key
  }

type BatchHandler es msg = [Ingested es msg] -> BatchInfo -> Eff es [AckDecision]

data QueueProcessor es msg
  = SingleProcessor (Adapter es msg) (Handler es msg) Ordering Concurrency
  | BatchProcessor  (Adapter es msg) (Handler es msg) (BatchHandler es msg) BatchConfig Ordering Concurrency
```

**Why it matters:** Most real-world queue consumers need batching for efficient downstream writes (database bulk inserts, API batch calls, S3 multipart uploads). Without it, users must implement their own accumulation logic, which is error-prone and misses backpressure integration.

**Implementation approach:**
- Add a `Batcher` stage that accumulates messages from the processor inbox
- Use `STM` `TVar` for the accumulator + `registerDelay` for timeout
- On batch emit (size or timeout), call `BatchHandler`
- Ack all messages in the batch based on handler's decision
- Keep single-message processing as default; batching is opt-in

### Priority 2: Enforced Partitioning (High Impact, Medium Effort)

**What:** Implement hash-based partition routing so `PartitionedInOrder` is enforced by the framework, not just documented.

**Design sketch:**
```haskell
data QueueProcessor es msg = QueueProcessor
  { ...
  , partitionBy :: Maybe (msg -> Int)  -- hash function
  }
```

**Implementation approach:**
- When `partitionBy` is set, create N internal bounded inboxes (one per partition slot)
- Ingester hashes each message and routes to the correct inbox
- Each partition inbox gets its own processing loop (serial within partition)
- Partitions process concurrently across each other
- This naturally enforces `PartitionedInOrder` semantics

**Why it matters:** Kafka, SQS FIFO, and many other queues have partition semantics. Users shouldn't have to implement this themselves.

### Priority 3: Rate Limiting (Medium Impact, Low Effort)

**What:** Add configurable rate limiting at the ingester level.

**Design sketch:**
```haskell
data RateLimitConfig = RateLimitConfig
  { allowedMessages :: Int
  , interval        :: NominalDiffTime
  }

data QueueProcessor es msg = QueueProcessor
  { ...
  , rateLimit :: Maybe RateLimitConfig
  }
```

**Implementation approach:**
- Token bucket algorithm in the ingester
- Use `TVar Int` for token count + periodic refill via `registerDelay`
- Ingester checks tokens before sending to inbox; blocks if none available
- Expose `updateRateLimit :: AppHandle es -> ProcessorId -> RateLimitConfig -> Eff es ()` for runtime adjustment

**Why it matters:** Downstream services often have rate limits (APIs, databases). Without framework-level support, users resort to `threadDelay` hacks that don't compose with backpressure.

### Priority 4: Richer Supervision (Medium Impact, High Effort)

**What:** Support per-processor restart strategies.

**Target capabilities:**
- Individual processor restart on failure (one-for-one)
- Configurable restart limits (max N restarts in M seconds)
- Auto-resubscribe to adapter after restart
- Exponential backoff between restarts

**Design sketch:**
```haskell
data RestartStrategy
  = NoRestart           -- current IgnoreFailures behavior
  | RestartOnFailure RestartConfig
  | StopAllOnFailure    -- current behavior

data RestartConfig = RestartConfig
  { maxRestarts     :: Int
  , withinSeconds   :: NominalDiffTime
  , backoffStrategy :: BackoffStrategy
  }

data BackoffStrategy = FixedDelay NominalDiffTime | ExponentialBackoff NominalDiffTime
```

**Why it matters:** In production, transient failures (network blips, temporary DB unavailability) are common. The ability to restart a single processor without affecting others is essential for long-running services.

**Note:** This may require changes to NQE or an alternative supervision mechanism.

### Priority 5: `handle_failed` Callback (Medium Impact, Low Effort)

**What:** Add an optional callback invoked when a message fails (exception or explicit failure).

**Design sketch:**
```haskell
data QueueProcessor es msg = QueueProcessor
  { ...
  , onFailure :: Maybe (Ingested es msg -> SomeException -> Eff es AckDecision)
  }
```

**Why it matters:** Common patterns like logging failures to a monitoring system, adjusting ack behavior based on failure type, or implementing custom retry logic all need this hook. Currently, users must wrap their handlers in try/catch.

### Priority 6: Message Transformer (Low Impact, Low Effort)

**What:** Optional transformation step between adapter and handler.

**Design sketch:**
```haskell
data QueueProcessor es msg where
  QueueProcessor :: Adapter es raw -> (raw -> Eff es msg) -> Handler es msg -> ... -> QueueProcessor es msg
```

**Why it matters:** Separates deserialization/enrichment from business logic. Makes adapters more reusable (same adapter, different transformers for different consumers).

### Priority 7: Prepare Messages / Batch Preprocessing (Low Impact, Low Effort)

**What:** Optional callback to preprocess a batch of messages before individual handling (e.g., bulk database lookups for enrichment).

**Design sketch:**
```haskell
data QueueProcessor es msg = QueueProcessor
  { ...
  , prepareMessages :: Maybe ([Ingested es msg] -> Eff es [Ingested es msg])
  }
```

**Why it matters:** Avoids N+1 queries when handlers need to look up related data. Broadway's `prepare_messages/2` is widely used for this.

### Priority 8: Testing Improvements (Medium Impact, Low Effort)

**What:** Richer testing utilities closer to Broadway's `test_message`/`test_batch`.

**Additions:**
```haskell
-- Send a single message through a running pipeline and get ack result
testMessage :: AppHandle es -> ProcessorId -> msg -> Eff es AckDecision

-- Send a batch and get all ack results
testBatch :: AppHandle es -> ProcessorId -> [msg] -> Eff es [AckDecision]

-- Assert helpers
assertAcked :: [AckDecision] -> Expectation
assertAllOk :: [AckDecision] -> Expectation
```

**Why it matters:** Easier testing → faster iteration → better adoption. The current `listAdapter` + `TrackingAck` pattern works but requires more boilerplate than Broadway's one-liner `test_message`.

### Priority 9: Multiple Producers per Processor (Low Impact, Medium Effort)

**What:** Allow a processor to consume from multiple adapters concurrently.

**Design sketch:**
```haskell
data QueueProcessor es msg = QueueProcessor
  { adapters :: NonEmpty (Adapter es msg)  -- was: adapter :: Adapter es msg
  , ...
  }
```

**Implementation:** Merge multiple Streamly streams into one before the ingester.

**Why it matters:** Some architectures fan-in from multiple sources (e.g., primary queue + retry queue + DLQ reprocessing).

### Priority 10: Dynamic Configuration (Low Impact, High Effort)

**What:** Allow runtime updates to processor configuration (concurrency, inbox size, rate limits).

**Why it matters:** Production tuning without restarts. Broadway supports runtime rate limit updates and ETS-backed configuration for dynamic pipelines.

---

## Summary

Shibuya has a solid foundation with genuine advantages (typed effects, AckHalt, leases, Streamly fusion). The most impactful improvements are:

1. **Batching** — the single largest feature gap; unlocks most real-world use cases
2. **Enforced partitioning** — moves ordering from documentation to runtime enforcement
3. **Rate limiting** — small effort, big production value
4. **Richer supervision** — essential for long-running production services

These four features would close ~80% of the gap with Broadway while preserving Shibuya's Haskell-native advantages.
