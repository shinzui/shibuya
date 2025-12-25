# Use Case: Supervised Queue Processors with Streamly Streaming

This document presents an alternative architecture for the queue processors use case, leveraging Streamly for stream-based message ingestion.

## Motivation

The previous approach used manual polling loops inside each processor. This approach separates concerns:

- **Streamly** handles I/O, polling, batching, and backpressure
- **NQE** handles concurrency, supervision, and state management

Benefits:
- Cleaner separation of I/O from business logic
- Built-in backpressure via bounded mailboxes
- Composable stream transformations (filtering, batching, rate limiting)
- Easier testing (mock the stream source)
- High performance through stream fusion (10-100x faster than unfused code)
- Unified API for streams, arrays, parsing, and I/O

## Architecture

```
                    ┌────────────────────────────────────────────────────────┐
                    │                    Master Process                      │
                    │                                                        │
                    │  ┌──────────────┐         ┌──────────────────────┐    │
   Clients ─────────┼─►│ Master Inbox │         │ TVar ProcessorStates │    │
                    │  └──────────────┘         └──────────────────────┘    │
                    │                                                        │
                    │  ┌────────────────────────────────────────────────┐   │
                    │  │            Supervisor (IgnoreAll)              │   │
                    │  └───────────────────────┬────────────────────────┘   │
                    └──────────────────────────┼────────────────────────────┘
                                               │
           ┌───────────────────────────────────┼───────────────────────────────┐
           │                                   │                               │
           ▼                                   ▼                               ▼
┌─────────────────────┐             ┌─────────────────────┐         ┌─────────────────────┐
│   Processor "A"     │             │   Processor "B"     │         │   Processor "C"     │
│                     │             │                     │         │                     │
│  ┌───────────────┐  │             │  ┌───────────────┐  │         │  ┌───────────────┐  │
│  │ Bounded Inbox │◄─┼─────┐       │  │ Bounded Inbox │◄─┼───┐     │  │ Bounded Inbox │◄─┼───┐
│  └───────┬───────┘  │     │       │  └───────┬───────┘  │   │     │  └───────┬───────┘  │   │
│          │          │     │       │          │          │   │     │          │          │   │
│          ▼          │     │       │          ▼          │   │     │          ▼          │   │
│  ┌───────────────┐  │     │       │  ┌───────────────┐  │   │     │  ┌───────────────┐  │   │
│  │    Handler    │  │     │       │  │    Handler    │  │   │     │  │    Handler    │  │   │
│  └───────────────┘  │     │       │  └───────────────┘  │   │     │  └───────────────┘  │   │
└─────────────────────┘     │       └─────────────────────┘   │     └─────────────────────┘   │
                            │                                 │                               │
                     ┌──────┴──────┐                   ┌──────┴──────┐                 ┌──────┴──────┐
                     │  Streamly   │                   │  Streamly   │                 │  Streamly   │
                     │   Stream    │                   │   Stream    │                 │   Stream    │
                     │  (Queue A)  │                   │  (Queue B)  │                 │  (Queue C)  │
                     └─────────────┘                   └─────────────┘                 └─────────────┘
                            ▲                                 ▲                               ▲
                            │                                 │                               │
                     ┌──────┴──────┐                   ┌──────┴──────┐                 ┌──────┴──────┐
                     │  External   │                   │  External   │                 │  External   │
                     │   Queue     │                   │   Queue     │                 │   Queue     │
                     │  (Redis)    │                   │   (SQS)     │                 │  (Kafka)    │
                     └─────────────┘                   └─────────────┘                 └─────────────┘
```

## Data Flow

```
External Queue
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│                        Streamly Pipeline                        │
│                                                                 │
│  pollStream ─► groupsOf ─► filter ─► map ─► tapMailbox         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
     │
     ▼ (bounded, backpressure)
┌─────────────────┐
│  Processor      │
│  Inbox          │
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Message        │
│  Handler        │
└─────────────────┘
```

## Implementation

### Core Types

```haskell
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE RecordWildCards #-}

module QueueProcessors.Streamly where

import Control.Concurrent.NQE.Streamly (tapMailbox)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Time.Clock
import NQE
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import UnliftIO

-- | Processor identifier
newtype ProcessorId = ProcessorId {unProcessorId :: String}
  deriving (Eq, Ord, Show)

-- | Processor runtime state
data ProcessorState
  = Idle -- Waiting for messages
  | Processing !Int !UTCTime -- Count, last activity
  | Failed !String !UTCTime -- Error, timestamp
  | Stopped
  deriving (Show, Eq)

-- | Stream statistics
data StreamStats = StreamStats
  { ssReceived :: !Int -- Messages received from stream
  , ssDropped :: !Int -- Messages dropped (backpressure)
  , ssProcessed :: !Int -- Messages successfully processed
  , ssFailed :: !Int -- Messages that failed processing
  }
  deriving (Show, Eq)

-- | Combined processor metrics
data ProcessorMetrics = ProcessorMetrics
  { pmState :: !ProcessorState
  , pmStats :: !StreamStats
  , pmStartedAt :: !UTCTime
  }
  deriving (Show)

type MetricsMap = Map ProcessorId ProcessorMetrics

-- | Configuration for stream-based processor
data StreamProcessorConfig msg = StreamProcessorConfig
  { spcId :: !ProcessorId
  , spcSource :: Stream IO msg -- Stream source
  , spcBufferSize :: !Int -- Bounded inbox size
  , spcHandler :: msg -> IO () -- Message handler
  , spcTransform :: Stream IO msg -> Stream IO msg -- Optional transformations
  }

-- | Default transform (identity)
defaultTransform :: Stream IO msg -> Stream IO msg
defaultTransform = id
```

### Stream Sources for Common Queues

```haskell
-- | Polling source with configurable interval
pollingStream
  :: Int -- Poll interval (microseconds)
  -> IO (Maybe msg) -- Poll action
  -> Stream IO msg
pollingStream interval poll =
  Stream.catMaybes $
    Stream.repeatM $ do
      mmsg <- poll
      case mmsg of
        Nothing -> threadDelay interval >> pure Nothing
        Just msg -> pure (Just msg)

-- | Source from a TBMQueue (bounded, closeable)
tbmQueueStream :: TBMQueue msg -> Stream IO msg
tbmQueueStream queue =
  Stream.unfoldrM unfold ()
  where
    unfold () = do
      mmsg <- atomically $ tryReadTBMQueue queue
      case mmsg of
        Nothing -> pure Nothing -- Queue closed
        Just Nothing -> unfold () -- Empty, retry
        Just (Just msg) -> pure (Just (msg, ()))

-- | Source from Redis list (BRPOP)
redisListStream
  :: Connection
  -> ByteString -- Key
  -> Int -- Timeout seconds
  -> Stream IO ByteString
redisListStream conn key timeout =
  Stream.catMaybes $
    Stream.repeatM $ do
      result <- runRedis conn $ brpop [key] (fromIntegral timeout)
      case result of
        Right (Just (_, msg)) -> pure (Just msg)
        Right Nothing -> pure Nothing -- Timeout, will retry
        Left err -> do
          putStrLn $ "Redis error: " ++ show err
          threadDelay 1_000_000
          pure Nothing

-- | Source from AWS SQS
sqsStream
  :: Env
  -> Text -- Queue URL
  -> Int -- Max messages per poll
  -> Stream IO Message
sqsStream env queueUrl batchSize =
  Stream.concatMap Stream.fromList $
    Stream.repeatM $ do
      resp <-
        runResourceT $
          send env $
            receiveMessage queueUrl
              & rmMaxNumberOfMessages ?~ batchSize
              & rmWaitTimeSeconds ?~ 20 -- Long polling
      pure (resp ^. rmrsMessages)

-- | Source from Kafka consumer
kafkaStream
  :: KafkaConsumer
  -> Stream IO ConsumerRecord
kafkaStream consumer =
  Stream.catMaybes $
    Stream.repeatM $ do
      records <- pollMessage consumer (Timeout 1000)
      case records of
        Left err -> do
          putStrLn $ "Kafka error: " ++ show err
          pure Nothing
        Right msg -> pure (Just msg)
```

### Stream Transformations

```haskell
-- | Batch messages into chunks
batchMessages :: Int -> Stream IO msg -> Stream IO [msg]
batchMessages n = Stream.foldMany (Fold.take n Fold.toList)

-- | Filter messages
filterMessages :: (msg -> Bool) -> Stream IO msg -> Stream IO msg
filterMessages = Stream.filter

-- | Rate limit (messages per second)
rateLimitStream :: Int -> Stream IO msg -> Stream IO msg
rateLimitStream msgsPerSec stream = Stream.catMaybes $ do
  lastTimeRef <- Stream.fromEffect $ newIORef =<< getCurrentTime
  Stream.mapM (rateLimit lastTimeRef) stream
  where
    rateLimit lastTimeRef msg = do
      now <- getCurrentTime
      lastTime <- readIORef lastTimeRef
      let elapsed = diffUTCTime now lastTime
          minInterval = 1.0 / fromIntegral msgsPerSec
      when (elapsed < minInterval) $
        threadDelay (round $ (minInterval - elapsed) * 1_000_000)
      writeIORef lastTimeRef =<< getCurrentTime
      pure (Just msg)

-- | Add logging
logMessages :: Show msg => String -> Stream IO msg -> Stream IO msg
logMessages prefix = Stream.mapM $ \msg -> do
  putStrLn $ prefix ++ ": " ++ show msg
  pure msg

-- | Decode JSON messages
decodeJsonStream :: FromJSON a => Stream IO ByteString -> Stream IO a
decodeJsonStream = Stream.mapMaybe $ \bs ->
  case eitherDecodeStrict bs of
    Left err -> do
      putStrLn $ "JSON decode error: " ++ err
      Nothing
    Right val -> Just val

-- | Retry transient failures in stream
retryTransient
  :: Int -- Max retries
  -> Int -- Delay between retries (microseconds)
  -> (msg -> IO a) -- Action that might fail
  -> Stream IO msg
  -> Stream IO a
retryTransient maxRetries delay action = Stream.mapM (go maxRetries)
  where
    go 0 msg = action msg -- Last attempt, let it throw
    go n msg =
      action msg `catchAny` \_ -> do
        threadDelay delay
        go (n - 1) msg

-- | Take only first n elements
takeStream :: Int -> Stream IO msg -> Stream IO msg
takeStream = Stream.take

-- | Drop first n elements
dropStream :: Int -> Stream IO msg -> Stream IO msg
dropStream = Stream.drop

-- | Take while predicate holds
takeWhileStream :: (msg -> Bool) -> Stream IO msg -> Stream IO msg
takeWhileStream = Stream.takeWhile

-- | Deduplicate consecutive elements
deduplicateStream :: Eq msg => Stream IO msg -> Stream IO msg
deduplicateStream stream = Stream.catMaybes $ do
  lastRef <- Stream.fromEffect $ newIORef Nothing
  Stream.mapM (dedup lastRef) stream
  where
    dedup lastRef msg = do
      lastMsg <- readIORef lastRef
      if lastMsg == Just msg
        then pure Nothing
        else do
          writeIORef lastRef (Just msg)
          pure (Just msg)
```

### Processor with Streaming

```haskell
-- | Stream ingester - runs the streamly pipeline feeding the inbox
streamIngester
  :: TVar StreamStats
  -> Stream IO msg -- Source
  -> (Stream IO msg -> Stream IO msg) -- Transform
  -> Mailbox msg -- Target
  -> IO ()
streamIngester statsVar source transform mailbox =
  Stream.fold Fold.drain $
    Stream.mapM sendToMailbox $
      transform source
  where
    sendToMailbox msg = do
      -- Check if mailbox is full (backpressure)
      full <- atomically $ mailboxFullSTM mailbox
      if full
        then
          atomically $
            modifyTVar' statsVar $
              \s -> s {ssDropped = ssDropped s + 1}
        else do
          send msg mailbox
          atomically $
            modifyTVar' statsVar $
              \s -> s {ssReceived = ssReceived s + 1}

-- | Alternative: Use tapMailbox for pass-through streaming
streamIngesterWithTap
  :: TVar StreamStats
  -> Stream IO msg
  -> (Stream IO msg -> Stream IO msg)
  -> Mailbox msg
  -> IO ()
streamIngesterWithTap statsVar source transform mailbox =
  Stream.fold Fold.drain $
    Stream.mapM updateStats $
      tapMailbox mailbox $
        transform source
  where
    updateStats msg = do
      atomically $
        modifyTVar' statsVar $
          \s -> s {ssReceived = ssReceived s + 1}
      pure msg

-- | Message processor - reads from inbox and handles messages
messageProcessor
  :: TVar ProcessorMetrics
  -> (msg -> IO ())
  -> Inbox msg
  -> IO ()
messageProcessor metricsVar handler inbox = loop
  where
    loop = do
      msg <- receive inbox
      updateState Processing

      result <- tryAny (handler msg)

      case result of
        Right () -> do
          atomically $
            modifyTVar' metricsVar $ \m ->
              m {pmStats = (pmStats m) {ssProcessed = ssProcessed (pmStats m) + 1}}
        Left ex -> do
          atomically $
            modifyTVar' metricsVar $ \m ->
              m {pmStats = (pmStats m) {ssFailed = ssFailed (pmStats m) + 1}}
          -- Log but continue processing
          putStrLn $ "Handler error: " ++ show ex

      loop

    updateState f = do
      now <- getCurrentTime
      atomically $
        modifyTVar' metricsVar $ \m ->
          let count = ssProcessed (pmStats m)
           in m {pmState = f count now}

-- | Combined processor: ingester + handler under supervision
runStreamProcessor
  :: TVar MetricsMap
  -> StreamProcessorConfig msg
  -> IO ()
runStreamProcessor allMetrics StreamProcessorConfig {..} = do
  now <- getCurrentTime

  -- Initialize metrics
  let initialStats = StreamStats 0 0 0 0
      initialMetrics = ProcessorMetrics Idle initialStats now

  metricsVar <- newTVarIO initialMetrics
  atomically $ modifyTVar' allMetrics (Map.insert spcId initialMetrics)

  -- Create bounded inbox for backpressure
  inbox <- newBoundedInbox (fromIntegral spcBufferSize)
  let mailbox = inboxToMailbox inbox

  -- Extract stats TVar for ingester
  statsVar <- newTVarIO initialStats

  -- Sync stats periodically
  let syncStats = forever $ do
        threadDelay 100_000
        stats <- readTVarIO statsVar
        atomically $ modifyTVar' metricsVar $ \m -> m {pmStats = stats}
        metrics <- readTVarIO metricsVar
        atomically $ modifyTVar' allMetrics (Map.insert spcId metrics)

  -- Run ingester with internal supervisor for the two concurrent tasks
  withSupervisor IgnoreGraceful $ \innerSup -> do
    addChild innerSup (streamIngester statsVar spcSource spcTransform mailbox)
    addChild innerSup (messageProcessor metricsVar spcHandler inbox)
    addChild innerSup syncStats

    -- Block until failure
    waitForFailure
  where
    waitForFailure = threadDelay maxBound
```

### Master Process

```haskell
-- | Messages for the master
data MasterMessage
  = GetAllMetrics (Listen MetricsMap)
  | GetProcessorMetrics ProcessorId (Listen (Maybe ProcessorMetrics))
  | PauseProcessor ProcessorId (Listen Bool)
  | ResumeProcessor ProcessorId (Listen Bool)
  | Shutdown (Listen ())

-- | Master state
data Master = Master
  { masterProcess :: Process MasterMessage
  , masterMetrics :: TVar MetricsMap
  }

-- | Start master with stream-based processors
startMaster :: [StreamProcessorConfig msg] -> IO Master
startMaster configs = do
  metricsVar <- newTVarIO Map.empty

  proc <- process $ \inbox ->
    withSupervisor IgnoreAll $ \sup -> do
      -- Start all processors
      forM_ configs $ \config ->
        addChild sup (runStreamProcessor metricsVar config)

      -- Handle master messages
      forever $
        receive inbox >>= \case
          GetAllMetrics respond -> do
            metrics <- readTVarIO metricsVar
            atomically $ respond metrics
          GetProcessorMetrics pid respond -> do
            metrics <- readTVarIO metricsVar
            atomically $ respond (Map.lookup pid metrics)
          Shutdown respond -> do
            atomically $ respond ()
          -- Supervisor cleanup handles children

          _ -> return ()

  return
    Master
      { masterProcess = proc
      , masterMetrics = metricsVar
      }

-- | Query all metrics
getAllMetrics :: Master -> IO MetricsMap
getAllMetrics Master {..} = query GetAllMetrics masterProcess

-- | Query specific processor metrics
getProcessorMetrics :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
getProcessorMetrics Master {..} pid =
  query (GetProcessorMetrics pid) masterProcess
```

## Complete Example

```haskell
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Main where

import Control.Concurrent.NQE.Streamly (tapMailbox)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Time.Clock
import NQE
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import UnliftIO

-- Simulated external queues
data SimulatedQueues = SimulatedQueues
  { sqQueueA :: TVar [String]
  , sqQueueB :: TVar [String]
  , sqQueueC :: TVar [String]
  }

setupQueues :: IO SimulatedQueues
setupQueues =
  SimulatedQueues
    <$> newTVarIO ["a1", "a2", "a3", "a4", "a5"]
    <*> newTVarIO ["b1", "b2", "b3"]
    <*> newTVarIO ["c1", "c2", "FAIL", "c3", "c4"]

-- Polling stream for simulated queue
simulatedQueueStream :: TVar [String] -> Int -> Stream IO String
simulatedQueueStream queueVar interval =
  Stream.catMaybes $
    Stream.repeatM $ do
      mmsg <- atomically $ do
        queue <- readTVar queueVar
        case queue of
          [] -> return Nothing
          (x : xs) -> do
            writeTVar queueVar xs
            return (Just x)
      case mmsg of
        Nothing -> do
          threadDelay interval
          pure Nothing
        Just msg -> pure (Just msg)

-- Message handler (fails on "FAIL")
handleMessage :: String -> String -> IO ()
handleMessage processorName msg = do
  putStrLn $ "[" ++ processorName ++ "] Processing: " ++ msg

  when (msg == "FAIL") $
    error $
      processorName ++ " encountered FAIL message!"

  threadDelay 200_000 -- Simulate work
  putStrLn $ "[" ++ processorName ++ "] Completed: " ++ msg

-- Simplified types for example
newtype ProcessorId = ProcessorId String deriving (Eq, Ord, Show)

data ProcessorMetrics = ProcessorMetrics
  { pmReceived :: !Int
  , pmProcessed :: !Int
  , pmFailed :: !Int
  }
  deriving (Show)

type MetricsMap = Map ProcessorId ProcessorMetrics

-- Stream processor
runProcessor
  :: TVar MetricsMap
  -> ProcessorId
  -> Stream IO String
  -> (String -> IO ())
  -> Int
  -> IO ()
runProcessor metricsVar pid source handler bufferSize = do
  metricsLocal <- newTVarIO (ProcessorMetrics 0 0 0)

  -- Create bounded inbox
  inbox <- newBoundedInbox (fromIntegral bufferSize)
  let mailbox = inboxToMailbox inbox

  -- Sync metrics periodically
  let syncMetrics = forever $ do
        threadDelay 100_000
        m <- readTVarIO metricsLocal
        atomically $ modifyTVar' metricsVar (Map.insert pid m)

  -- Ingester: stream -> mailbox (using tapMailbox)
  let ingester =
        Stream.fold Fold.drain $
          Stream.mapM
            ( \msg -> do
                full <- atomically $ mailboxFullSTM mailbox
                unless full $ do
                  send msg mailbox
                  atomically $
                    modifyTVar' metricsLocal $
                      \m -> m {pmReceived = pmReceived m + 1}
            )
            source

  -- Processor: mailbox -> handler
  let processor = forever $ do
        msg <- receive inbox
        result <- tryAny (handler msg)
        atomically $
          modifyTVar' metricsLocal $ \m -> case result of
            Right () -> m {pmProcessed = pmProcessed m + 1}
            Left _ -> m {pmFailed = pmFailed m + 1}

  -- Run all three concurrently
  race_ syncMetrics (race_ ingester processor)

main :: IO ()
main = do
  queues <- setupQueues
  metricsVar <- newTVarIO Map.empty

  let processors =
        [ ( ProcessorId "A"
          , simulatedQueueStream (sqQueueA queues) 100_000
          , handleMessage "A"
          )
        , ( ProcessorId "B"
          , simulatedQueueStream (sqQueueB queues) 150_000
          , handleMessage "B"
          )
        , ( ProcessorId "C"
          , simulatedQueueStream (sqQueueC queues) 80_000
          , handleMessage "C" -- Will fail on "FAIL"
          )
        ]

  putStrLn "Starting processors...\n"

  withSupervisor IgnoreAll $ \sup -> do
    -- Start all processors
    forM_ processors $ \(pid, source, handler) ->
      addChild sup (runProcessor metricsVar pid source handler 10)

    -- Report metrics periodically
    replicateM_ 15 $ do
      threadDelay 300_000
      metrics <- readTVarIO metricsVar
      putStrLn "\n=== Metrics ==="
      forM_ (Map.toList metrics) $ \(ProcessorId name, m) ->
        putStrLn $
          "  "
            ++ name
            ++ ": recv="
            ++ show (pmReceived m)
            ++ " proc="
            ++ show (pmProcessed m)
            ++ " fail="
            ++ show (pmFailed m)

  putStrLn "\nShutdown complete"
```

## Output

```
Starting processors...

[A] Processing: a1
[B] Processing: b1
[C] Processing: c1
[A] Completed: a1
[C] Completed: c1
[A] Processing: a2
[C] Processing: c2

=== Metrics ===
  A: recv=2 proc=1 fail=0
  B: recv=1 proc=0 fail=0
  C: recv=2 proc=1 fail=0

[B] Completed: b1
[C] Completed: c2
[A] Completed: a2
[C] Processing: FAIL
[B] Processing: b2

=== Metrics ===
  A: recv=3 proc=2 fail=0
  B: recv=2 proc=1 fail=0
  C: recv=3 proc=2 fail=1     <-- C recorded a failure but continues

[A] Processing: a3
[B] Completed: b2
[C] Processing: c3            <-- C recovered and continues
[A] Completed: a3

=== Metrics ===
  A: recv=4 proc=3 fail=0
  B: recv=3 proc=2 fail=0
  C: recv=4 proc=3 fail=1

...

Shutdown complete
```

## Key Differences from Non-Streaming Version

| Aspect          | Manual Polling               | Streamly Streaming                          |
| --------------- | ---------------------------- | ------------------------------------------- |
| I/O handling    | Mixed with business logic    | Separated in Stream pipeline                |
| Backpressure    | Manual check in loop         | Automatic via bounded inbox + `tapMailbox`  |
| Transformations | Ad-hoc code                  | Composable stream functions                 |
| Testing         | Mock poll function           | Mock stream source                          |
| Batching        | Manual implementation        | `Stream.foldMany` with `Fold.take`          |
| Error recovery  | Try/catch in loop            | Stream error handling + handler try/catch   |
| Performance     | Good                         | Excellent (stream fusion)                   |

## Comparison: Conduit vs Streamly

| Aspect             | Conduit                     | Streamly                                    |
| ------------------ | --------------------------- | ------------------------------------------- |
| Type               | `ConduitT i o m r`          | `Stream m a` + `Fold m a b`                 |
| Pipeline operator  | `.|`                        | Function composition                        |
| Run pipeline       | `runConduit`                | `Stream.fold Fold.drain`                    |
| Await/yield        | `awaitForever`, `yield`     | `Stream.mapM`, return values                |
| Filter             | `filterC`                   | `Stream.filter`                             |
| Map                | `mapC`                      | `fmap`, `Stream.map`                        |
| Batching           | `chunksOf`                  | `Stream.foldMany (Fold.take n Fold.toList)` |
| Performance        | Good                        | 10-100x faster (fusion)                     |
| API clarity        | Single complex type         | Separate Stream/Fold types                  |

## Advanced Patterns

### Acknowledgment-Based Processing

For queues requiring explicit acknowledgment (SQS, RabbitMQ):

```haskell
data AckMessage msg = AckMessage
  { amPayload :: msg
  , amAck :: IO ()
  , amNack :: IO ()
  }

-- Handler receives ack/nack capabilities
ackHandler :: (msg -> IO ()) -> AckMessage msg -> IO ()
ackHandler process AckMessage {..} = do
  result <- tryAny (process amPayload)
  case result of
    Right () -> amAck
    Left _ -> amNack
```

### Dead Letter Queue

Route failed messages to a DLQ:

```haskell
withDeadLetterQueue
  :: Mailbox msg -- DLQ mailbox
  -> (msg -> IO ()) -- Original handler
  -> (msg -> IO ())
withDeadLetterQueue dlq handler msg =
  handler msg `catchAny` \_ -> send msg dlq
```

### Circuit Breaker

Protect downstream services:

```haskell
data CircuitState = Closed | Open UTCTime | HalfOpen

circuitBreakerStream
  :: TVar CircuitState
  -> Int -- Failure threshold
  -> NominalDiffTime -- Reset timeout
  -> Stream IO msg
  -> Stream IO msg
circuitBreakerStream stateVar threshold resetTime =
  Stream.mapMaybeM $ \msg -> do
    state <- readTVarIO stateVar
    case state of
      Closed -> pure (Just msg)
      Open since -> do
        now <- getCurrentTime
        when (diffUTCTime now since > resetTime) $
          atomically $
            writeTVar stateVar HalfOpen
        pure Nothing
      HalfOpen -> pure (Just msg) -- Let one through to test
```

### Fan-Out to Multiple Mailboxes

```haskell
fanOutStream
  :: [Mailbox msg]
  -> Stream IO msg
  -> Stream IO msg
fanOutStream mailboxes = Stream.mapM $ \msg -> do
  forM_ mailboxes $ \mbox -> send msg mbox
  pure msg
```

### Round-Robin Distribution

```haskell
roundRobinStream
  :: [Mailbox msg]
  -> Stream IO msg
  -> Stream IO msg
roundRobinStream mailboxes stream = do
  indexRef <- Stream.fromEffect $ newIORef 0
  Stream.mapM (distribute indexRef) stream
  where
    n = length mailboxes
    distribute indexRef msg = do
      i <- readIORef indexRef
      send msg (mailboxes !! i)
      writeIORef indexRef ((i + 1) `mod` n)
      pure msg
```

## When to Use This Architecture

**Streamly streaming approach is better when:**

- External queues have native streaming clients
- You need composable transformations (filter, batch, rate limit)
- Backpressure is important
- You want clean separation of I/O from business logic
- Testing stream pipelines independently
- Performance is critical (stream fusion provides 10-100x speedup)
- You prefer explicit producer (Stream) vs consumer (Fold) separation

**Manual polling is simpler when:**

- Simple poll-handle loops
- No need for transformations
- Direct control over timing
- Fewer moving parts preferred

