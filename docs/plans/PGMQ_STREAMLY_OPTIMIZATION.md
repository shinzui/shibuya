# PGMQ Adapter Streamly Optimization Analysis

This document provides a deep technical analysis of how to leverage Streamly to improve the performance of the shibuya-pgmq-adapter, ensuring messages are always ready for Shibuya to consume.

## Executive Summary

The current implementation has a critical inefficiency: it fetches batches of messages but only processes **one message per poll**, discarding the rest. By adopting patterns from message-db-hs and leveraging Streamly's concurrent combinators, we can:

1. **Process entire batches** - Use all messages fetched, not just the first
2. **Prefetch concurrently** - Poll the next batch while processing current messages
3. **Maintain backpressure** - Respect downstream capacity via bounded buffers
4. **Minimize latency** - Keep messages ready in a buffer for immediate consumption

## Current Implementation Analysis

### The Problem

In `shibuya-pgmq-adapter/src/Shibuya/Adapter/Pgmq/Internal.hs:233-241`:

```haskell
pgmqSource config =
  Stream.catMaybes $ Stream.repeatM pollAndConvert
  where
    pollAndConvert = do
      msgs <- poll
      case Vector.uncons msgs of
        Nothing -> pure Nothing
        Just (msg, _rest) -> mkIngested config msg  -- ⚠️ Only first message!
```

**Critical Issue**: When `batchSize = 10`, we fetch 10 messages but only use 1, then poll again. This means:
- 90% of fetched messages are discarded
- 10x more database roundtrips than necessary
- Increased visibility timeout pressure (messages re-appear after timeout)
- Poor throughput despite larger batch sizes

### The message-db-hs Pattern

In `message-db-effectful/src/MessageDb/Effectful/Streamly.hs`:

```haskell
-- Step 1: Create a stream of batches (Vector Message)
getCategoryMessageChunks :: ... -> Stream (Eff es) (Vector Message)
getCategoryMessageChunks query =
  S.unfoldrM queryStreamCategory (query ^. #globalPositionStart)
  where
    queryStreamCategory pos = do
      messages <- getCategoryMessages updatedQuery
      let nextBatchPosition = ...
      pure $ Just (messages, nextBatchPosition)

-- Step 2: Flatten batches into individual messages
categoryMessages :: ... -> Stream (Eff es) Message
categoryMessages query =
  getCategoryMessageChunks query
    & S.takeWhile (not . Vector.null)  -- Stop on empty
    & S.unfoldEach vectorUnfold        -- Flatten Vector to individual elements
```

**Key insight**: `S.unfoldEach vectorUnfold` expands each `Vector Message` into individual `Message` elements in the stream, using **all** messages from the batch.

## Proposed Architecture

### Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        pgmqSource (Stream)                               │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────────────────┐  │
│  │ pgmqChunks   │ -> │ unfoldEach   │ -> │ mapMaybeM mkIngested     │  │
│  │ (poll loop)  │    │ (flatten)    │    │ (convert + filter DLQ)   │  │
│  └──────────────┘    └──────────────┘    └──────────────────────────┘  │
│         │                                                               │
│         v                                                               │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                   parBuffered (prefetch)                          │  │
│  │  - Polls next batch while current is being processed              │  │
│  │  - Configurable buffer size                                       │  │
│  │  - Maintains backpressure                                         │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    v
                          ┌─────────────────┐
                          │    Ingester     │
                          │ (bounded inbox) │
                          └─────────────────┘
                                    │
                                    v
                          ┌─────────────────┐
                          │   Processor     │
                          │   (handler)     │
                          └─────────────────┘
```

### Layer 1: Chunk-Based Polling

```haskell
-- | Stream of message batches from pgmq.
-- Each element is a Vector of messages from a single poll.
pgmqChunks ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunks config = S.repeatM pollBatch
  where
    pollBatch :: Eff es (Vector Pgmq.Message)
    pollBatch = case config.fifoConfig of
      Nothing -> pollNonFifo
      Just fifo -> pollFifo fifo

    pollNonFifo = case config.polling of
      StandardPolling interval -> do
        result <- readMessage (mkReadMessage config)
        when (Vector.null result) $
          liftIO $ threadDelay (nominalToMicros interval)
        pure result
      LongPolling maxSec intervalMs ->
        readWithPoll (mkReadWithPoll config maxSec intervalMs)

    -- ... same for FIFO modes
```

### Layer 2: Batch Flattening

```haskell
-- | Flatten chunks into individual messages.
-- Uses Streamly's unfoldEach to expand each Vector.
pgmqMessages ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) Pgmq.Message
pgmqMessages config =
  pgmqChunks config
    & S.unfoldEach vectorUnfold
  where
    -- Unfold a Vector into a stream of elements
    vectorUnfold :: Unfold (Eff es) (Vector a) a
    vectorUnfold = Unfold.unfoldr Vector.uncons
```

### Layer 3: Conversion with Filtering

```haskell
-- | Convert pgmq messages to Shibuya Ingested.
-- Filters out auto-dead-lettered messages.
pgmqSource ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Ingested es Value)
pgmqSource config =
  pgmqMessages config
    & S.mapMaybeM (mkIngested config)  -- Filter + convert
```

### Layer 4: Concurrent Prefetching (Advanced)

```haskell
-- | Create source with prefetching enabled.
-- Uses Streamly's parBuffered to poll ahead while processing.
pgmqSourcePrefetch ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  PrefetchConfig ->
  Stream (Eff es) (Ingested es Value)
pgmqSourcePrefetch config prefetch =
  pgmqSource config
    & S.parBuffered (prefetchSettings prefetch)
  where
    prefetchSettings pf =
      S.maxBuffer pf.bufferSize
```

## Implementation Details

### 1. Efficient Vector Unfold

The key primitive is unfolding a `Vector` into a stream:

```haskell
-- Using tan-streamly pattern
vectorUnfold :: (Applicative m, Vector v a) => Unfold m (v a) a
vectorUnfold = Unfold.unfoldr Vector.uncons

-- Or inline with Streamly's unfoldEach
flattenBatches :: Stream (Eff es) (Vector a) -> Stream (Eff es) a
flattenBatches = S.unfoldEach vectorUnfold
```

### 2. Handling Empty Batches

Unlike message-db (which has a finite stream that ends), PGMQ is a continuous queue. Empty batches mean "no messages right now", not "end of stream":

```haskell
pgmqChunks config = S.repeatM $ do
  batch <- poll
  -- Don't stop on empty - just keep polling
  when (Vector.null batch) $
    liftIO $ threadDelay pollInterval
  pure batch

-- Then filter empty batches before unfolding
pgmqMessages config =
  pgmqChunks config
    & S.filter (not . Vector.null)  -- Skip empty batches
    & S.unfoldEach vectorUnfold
```

### 3. Visibility Timeout Considerations

When prefetching, messages become invisible immediately upon read. If we buffer too many:
- Messages may timeout before processing
- They'll reappear in queue and be processed twice

**Solution**: Configure `maxBuffer` based on:
```haskell
maxSafeBuffer = floor (visibilityTimeout / avgProcessingTime)
```

### 4. Backpressure Integration

Shibuya's Ingester already provides backpressure via bounded inbox:

```haskell
runIngesterWithMetrics metricsVar source inbox = do
  let mailbox = inboxToMailbox inbox
  Stream.fold Fold.drain $
    Stream.mapM
      ( \msg -> do
          liftIO $ send msg mailbox  -- Blocks when inbox full
          pure msg
      )
      source
```

The adapter's prefetch buffer + Ingester's inbox create two-stage backpressure:

```
Poll -> [Prefetch Buffer] -> [Inbox] -> Handler
         ^                    ^
         |                    |
         Backpressure        Backpressure
         (parBuffered)       (bounded mailbox)
```

## Configuration Updates

### New Configuration Types

```haskell
-- | Prefetch configuration for concurrent polling.
data PrefetchConfig = PrefetchConfig
  { -- | Enable concurrent prefetching
    enabled :: !Bool,
    -- | Maximum messages to buffer ahead
    -- Should be < visibilityTimeout / avgProcessingTime
    bufferSize :: !Int
  }
  deriving stock (Show, Eq, Generic)

-- | Default prefetch configuration (disabled)
defaultPrefetchConfig :: PrefetchConfig
defaultPrefetchConfig = PrefetchConfig
  { enabled = False,
    bufferSize = 100
  }

-- | Updated adapter config
data PgmqAdapterConfig = PgmqAdapterConfig
  { -- ... existing fields ...
    prefetchConfig :: !(Maybe PrefetchConfig)
  }
```

## Performance Comparison

### Current Implementation

| Metric | Value |
|--------|-------|
| Messages per poll used | 1 (of N fetched) |
| DB roundtrips per message | 1 |
| Efficiency | 1/batchSize (10% if batchSize=10) |
| Latency | Poll time + processing time (sequential) |

### Proposed Implementation

| Metric | Value |
|--------|-------|
| Messages per poll used | All N fetched |
| DB roundtrips per message | 1/batchSize |
| Efficiency | 100% |
| Latency | Processing time only (poll overlapped) |

### Expected Improvements

1. **Throughput**: Up to `batchSize` x improvement (e.g., 10x for batchSize=10)
2. **Latency**: Reduced by poll time when prefetching enabled
3. **Database Load**: Reduced by factor of batchSize

## Implementation Phases

### Phase 1: Fix Batch Wastage (High Priority)

Minimal change to use all messages from each batch:

```haskell
pgmqSource config =
  pgmqChunks config
    & S.filter (not . Vector.null)
    & S.unfoldEach vectorUnfold
    & S.mapMaybeM (mkIngested config)
```

**Impact**: Immediate 10x improvement (for batchSize=10)

### Phase 2: Add Prefetching (Medium Priority)

Add `parBuffered` for concurrent polling:

```haskell
pgmqSource config =
  pgmqChunks config
    & S.filter (not . Vector.null)
    & S.unfoldEach vectorUnfold
    & S.mapMaybeM (mkIngested config)
    & S.parBuffered (S.maxBuffer 100)  -- Prefetch up to 100 messages
```

**Impact**: Reduces latency by overlapping poll and processing

### Phase 3: Configurable Prefetching (Lower Priority)

Expose configuration for tuning:

```haskell
pgmqAdapter config = do
  shutdownVar <- newTVarIO False
  let source = case config.prefetchConfig of
        Nothing -> pgmqSource config
        Just pf -> pgmqSource config & S.parBuffered (S.maxBuffer pf.bufferSize)
  ...
```

## Testing Strategy

### Unit Tests

1. **Batch unfolding**: Verify all messages from batch are emitted
2. **Empty batch handling**: Verify polling continues after empty batches
3. **Auto-DLQ filtering**: Verify over-retry messages are filtered

### Integration Tests

1. **Throughput benchmark**: Measure messages/second with various batch sizes
2. **Latency measurement**: Compare poll-to-handler latency
3. **Visibility timeout**: Ensure no duplicate processing under load

### Property Tests

1. **No message loss**: All enqueued messages eventually processed
2. **Order preservation**: Within-batch ordering maintained (for non-FIFO)
3. **Backpressure**: Producer doesn't overwhelm consumer

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| Visibility timeout on buffered messages | Configure buffer size based on timeout/processing ratio |
| Memory usage with large batches | Bounded buffer + backpressure from Ingester |
| Concurrent polling race conditions | Streamly handles thread safety internally |
| effectful compatibility with parBuffered | May need `unsafeEff` wrapper or alternative approach |

## Dependencies

- **streamly**: Already used, may need to expose more internal combinators
- **streamly-core**: For `Unfold` utilities
- **No new dependencies required**

## Conclusion

The current implementation leaves significant performance on the table by discarding fetched messages. By adopting the message-db pattern of `S.unfoldEach vectorUnfold`, we can immediately achieve up to 10x improvement with minimal code changes. Adding `parBuffered` prefetching provides further latency reduction by overlapping polling with processing.

The proposed changes are backward compatible (same interface) and integrate cleanly with Shibuya's existing backpressure mechanisms.
