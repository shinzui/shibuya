-- | Controlled lifecycle and production-runner workloads for EP-45.
--
-- The tasty benchmarks provide quick local regression signals. The
-- @lifecycle-load@ executable runs the same scenarios once per process and
-- emits a machine-readable sample suitable for paired baseline/candidate
-- comparison. One scenario per process is intentional: GHC's live-memory
-- statistics are process high-water marks and must not leak across samples.
module Bench.Lifecycle
  ( LifecycleResult,
    Scenario,
    benchmarks,
    lifecycleResultValue,
    lookupScenario,
    overrideMessageCount,
    runLifecycleScenario,
    scenarioNames,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.Monad (replicateM, replicateM_, unless, when)
import Data.Aeson (Value, object, (.=))
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Data.Word (Word64)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Conc (getNumCapabilities)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App qualified as App
import Shibuya.Batch (BatchConfig (..), BatchHandler, BatchKey (..), ackAll, ackAllOk, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..), Message (..), mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Handler (Handler)
import Shibuya.Internal.Runner.Master (startMaster, stopMaster)
import Shibuya.Internal.Runner.Supervised
  ( SupervisedProcessor,
    getMetrics,
    isDone,
    runSupervised,
    runSupervisedBatch,
  )
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Mem (performMajorGC)
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)

data PartitionFixture
  = NoPartitions
  | UniformPartitions !Int
  | HotKeyPartitions !Int
  | HighCardinalityPartitions
  deriving stock (Eq, Show)

data DecisionFixture
  = AllAckOk
  | RetryEvery !Int
  | DeadLetterEvery !Int
  deriving stock (Eq, Show)

data BatchFixture
  = NoBatch
  | SizeBatch !Int
  | TimeoutBatch !Int !Int
  deriving stock (Eq, Show)

data ObserverFixture
  = NoObserver
  | MetricsPolling
  | HealthPollingProxy
  | WebSocketChurnProxy
  deriving stock (Eq, Show)

data ShutdownFixture
  = StopAfterDrain
  | GracefulDrainAfter !Int
  deriving stock (Eq, Show)

data Scenario = Scenario
  { name :: !Text,
    concurrency :: !Concurrency,
    ordering :: !OrderingPolicy,
    messageCount :: !Int,
    inboxSize :: !Int,
    handlerDelayMicros :: !Int,
    arrivalIntervalMicros :: !Int,
    partitions :: !PartitionFixture,
    decisions :: !DecisionFixture,
    batching :: !BatchFixture,
    observer :: !ObserverFixture,
    shutdown :: !ShutdownFixture,
    startupCycles :: !Int,
    idleBeforeFirstMessageMicros :: !Int
  }
  deriving stock (Show)

data BenchMessage = BenchMessage
  { sequenceNumber :: !Int,
    scheduledAtNs :: !Word64,
    body :: !Text
  }
  deriving stock (Show)

data Counters = Counters
  { completed :: !(IORef Int),
    acknowledged :: !(IORef Int),
    retried :: !(IORef Int),
    deadLettered :: !(IORef Int),
    latenciesNs :: !(IORef [Word64])
  }

data LifecycleResult = LifecycleResult
  { scenario :: !Scenario,
    expected :: !Int,
    completed :: !Int,
    acknowledged :: !Int,
    retried :: !Int,
    deadLettered :: !Int,
    elapsedNs :: !Word64,
    shutdownNs :: !Word64,
    p50Ns :: !Word64,
    p95Ns :: !Word64,
    p99Ns :: !Word64,
    allocatedBytes :: !Word64,
    maxLiveBytes :: !Word64,
    gcCpuNs :: !Word64,
    cpuNs :: !Word64,
    capabilities :: !Int
  }

scenarioNames :: [Text]
scenarioNames = map (.name) scenarios

lookupScenario :: Text -> Maybe Scenario
lookupScenario requested = findScenario scenarios
  where
    findScenario [] = Nothing
    findScenario (candidate : rest)
      | candidate.name == requested = Just candidate
      | otherwise = findScenario rest

overrideMessageCount :: Int -> Scenario -> Scenario
overrideMessageCount count scenario = scenario {messageCount = count}

benchmarks :: Benchmark
benchmarks =
  bgroup
    "lifecycle"
    [ benchScenario "serial-small-inbox",
      benchScenario "ahead-uniform-keys",
      benchScenario "async-hot-key",
      benchScenario "batch-size",
      benchScenario "startup-shutdown"
    ]
  where
    benchScenario requested =
      case lookupScenario requested of
        Nothing -> error ("missing lifecycle benchmark scenario: " <> Text.unpack requested)
        Just scenario ->
          bench (Text.unpack requested) $
            nfIO (resultCompleted <$> runLifecycleScenario scenario)

resultCompleted :: LifecycleResult -> Int
resultCompleted LifecycleResult {completed} = completed

runLifecycleScenario :: Scenario -> IO LifecycleResult
runLifecycleScenario scenario = do
  statsEnabled <- getRTSStatsEnabled
  when (not statsEnabled) $ ioError (userError "lifecycle-load requires RTS statistics; run with +RTS -T -RTS")
  performMajorGC
  before <- getRTSStats
  started <- getMonotonicTimeNSec
  counters <- newCounters
  shutdownSamples <-
    if scenario.startupCycles > 0
      then runStartupCycles scenario.startupCycles
      else
        (: []) <$> case scenario.shutdown of
          StopAfterDrain -> runMessageFlow scenario counters started
          GracefulDrainAfter completedCount ->
            runGracefulDrainFlow scenario counters started completedCount
  finished <- getMonotonicTimeNSec
  performMajorGC
  after <- getRTSStats
  completedCount <- readIORef counters.completed
  acknowledgedCount <- readIORef counters.acknowledged
  retriedCount <- readIORef counters.retried
  deadLetteredCount <- readIORef counters.deadLettered
  latencySamples <- readIORef counters.latenciesNs
  caps <- getNumCapabilities
  let isLifecycleOnly = scenario.startupCycles > 0
      expectedCount = if isLifecycleOnly then scenario.startupCycles else scenario.messageCount
      completed' = if isLifecycleOnly then scenario.startupCycles else completedCount
      acknowledged' = if isLifecycleOnly then scenario.startupCycles else acknowledgedCount
  pure
    LifecycleResult
      { scenario,
        expected = expectedCount,
        completed = completed',
        acknowledged = acknowledged',
        retried = retriedCount,
        deadLettered = deadLetteredCount,
        elapsedNs = finished - started,
        shutdownNs = quantile 0.95 shutdownSamples,
        p50Ns = quantile 0.50 latencySamples,
        p95Ns = quantile 0.95 latencySamples,
        p99Ns = quantile 0.99 latencySamples,
        allocatedBytes = delta allocated_bytes before after,
        maxLiveBytes = max_live_bytes after,
        gcCpuNs = deltaTime gc_cpu_ns before after,
        cpuNs = deltaTime cpu_ns before after,
        capabilities = caps
      }

runStartupCycles :: Int -> IO [Word64]
runStartupCycles count = replicateM count $ do
  start <- getMonotonicTimeNSec
  runEff $ runTracingNoop $ do
    master <- startMaster IgnoreAll
    stopMaster master
  end <- getMonotonicTimeNSec
  pure (end - start)

runMessageFlow :: Scenario -> Counters -> Word64 -> IO Word64
runMessageFlow scenario counters runStarted =
  runEff $ runTracingNoop $ do
    master <- startMaster IgnoreAll
    messages <- liftIO $ createMessages scenario counters runStarted
    let pacedSource = Stream.mapM (paceMessage scenario) (Stream.fromList messages)
        adapter =
          Adapter
            { adapterName = "bench:lifecycle:" <> scenario.name,
              source = pacedSource,
              shutdown = pure ()
            }
    processor <-
      case scenario.batching of
        NoBatch ->
          runSupervised
            master
            (fromIntegral scenario.inboxSize)
            (ProcessorId scenario.name)
            scenario.ordering
            scenario.concurrency
            adapter
            (messageHandler scenario counters)
        SizeBatch size ->
          runSupervisedBatch
            master
            (fromIntegral scenario.inboxSize)
            (ProcessorId scenario.name)
            scenario.concurrency
            (batchConfig size 60)
            adapter
            (batchHandler scenario counters)
        TimeoutBatch size timeoutMicros ->
          runSupervisedBatch
            master
            (fromIntegral scenario.inboxSize)
            (ProcessorId scenario.name)
            scenario.concurrency
            (batchConfig size (fromIntegral timeoutMicros / 1_000_000))
            adapter
            (batchHandler scenario counters)
    waitForDone scenario.observer processor
    shutdownStarted <- liftIO getMonotonicTimeNSec
    stopMaster master
    shutdownFinished <- liftIO getMonotonicTimeNSec
    pure (shutdownFinished - shutdownStarted)

-- | Measure the public graceful-shutdown path while the processor still has a
-- bounded backlog. Post-drain 'stopMaster' calls take only a few microseconds
-- and are useful correctness checks, but one observation per process is not a
-- statistically meaningful 10% shutdown-latency gate. This fixture times the
-- actual drain contract and still requires every delivery to be acknowledged.
runGracefulDrainFlow :: Scenario -> Counters -> Word64 -> Int -> IO Word64
runGracefulDrainFlow scenario counters runStarted stopAfter =
  runEff $ runTracingNoop $ do
    messages <- liftIO $ createMessages scenario counters runStarted
    let pacedSource = Stream.mapM (paceMessage scenario) (Stream.fromList messages)
        adapter =
          Adapter
            { adapterName = "bench:lifecycle:" <> scenario.name,
              source = pacedSource,
              shutdown = pure ()
            }
        processor =
          App.QueueProcessor
            adapter
            (messageHandler scenario counters)
            scenario.ordering
            scenario.concurrency
        appConfig = App.defaultAppConfig {App.inboxSize = scenario.inboxSize}
    appResult <- App.runApp appConfig [(ProcessorId scenario.name, processor)]
    app <-
      case appResult of
        Left err -> liftIO $ ioError (userError ("lifecycle app startup failed: " <> show err))
        Right handle -> pure handle
    waitForCompletions counters stopAfter
    shutdownStarted <- liftIO getMonotonicTimeNSec
    drained <-
      App.stopAppGracefully
        (App.defaultShutdownConfig {App.drainTimeout = 5})
        app
    shutdownFinished <- liftIO getMonotonicTimeNSec
    unless drained $ liftIO $ ioError (userError "graceful shutdown did not drain the lifecycle backlog")
    pure (shutdownFinished - shutdownStarted)

waitForCompletions :: (IOE :> es) => Counters -> Int -> Eff es ()
waitForCompletions counters target = do
  started <- liftIO getMonotonicTimeNSec
  go started
  where
    go started = do
      completed <- liftIO $ readIORef counters.completed
      if completed >= target
        then pure ()
        else do
          now <- liftIO getMonotonicTimeNSec
          when (now - started > 10_000_000_000) $
            liftIO $
              ioError (userError "lifecycle scenario did not reach the graceful-shutdown barrier")
          liftIO $ threadDelay 250
          go started

batchConfig :: Int -> Double -> BatchConfig es BenchMessage
batchConfig size timeoutSeconds =
  defaultBatchConfig
    { batchSize = size,
      batchTimeout = realToFrac timeoutSeconds,
      batchKey = \envelope -> BatchKey (fromMaybe "unpartitioned" envelope.partition),
      tickInterval = Just (realToFrac (min timeoutSeconds 0.005))
    }

messageHandler :: (IOE :> es) => Scenario -> Counters -> Handler es BenchMessage
messageHandler scenario counters message = do
  when (scenario.handlerDelayMicros > 0) $ liftIO $ threadDelay scenario.handlerDelayMicros
  liftIO $ atomicModifyIORef' counters.completed (\count -> (count + 1, ()))
  let Message {envelope = Envelope {payload = BenchMessage {sequenceNumber}}} = message
  pure $ decisionFor scenario.decisions sequenceNumber

batchHandler :: (IOE :> es) => Scenario -> Counters -> BatchHandler es BenchMessage
batchHandler scenario counters _ messages = do
  when (scenario.handlerDelayMicros > 0) $ liftIO $ threadDelay scenario.handlerDelayMicros
  let count = NonEmpty.length messages
  liftIO $ atomicModifyIORef' counters.completed (\current -> (current + count, ()))
  pure $
    case scenario.decisions of
      AllAckOk -> ackAllOk
      RetryEvery _ -> ackAll (AckRetry (RetryDelay 0))
      DeadLetterEvery _ -> ackAll (AckDeadLetter MaxRetriesExceeded)

paceMessage :: (IOE :> es) => Scenario -> Ingested es BenchMessage -> Eff es (Ingested es BenchMessage)
paceMessage scenario message = do
  let target = message.envelope.payload.scheduledAtNs
  now <- liftIO getMonotonicTimeNSec
  when (target > now) $ liftIO $ threadDelay (fromIntegral ((target - now) `div` 1_000))
  when (message.envelope.payload.sequenceNumber == 1 && scenario.idleBeforeFirstMessageMicros > 0) $
    liftIO $
      threadDelay scenario.idleBeforeFirstMessageMicros
  pure message

waitForDone :: (IOE :> es) => ObserverFixture -> SupervisedProcessor -> Eff es ()
waitForDone observer processor = do
  started <- liftIO getMonotonicTimeNSec
  go started
  where
    go started = do
      done <- isDone processor
      if done
        then pure ()
        else do
          observe observer processor
          now <- liftIO getMonotonicTimeNSec
          when (now - started > 120_000_000_000) $
            liftIO $
              ioError (userError "lifecycle scenario exceeded the 120 second safety bound")
          liftIO $ threadDelay 250
          go started

observe :: (IOE :> es) => ObserverFixture -> SupervisedProcessor -> Eff es ()
observe NoObserver _ = pure ()
observe MetricsPolling processor = getMetrics processor >> pure ()
observe HealthPollingProxy processor = getMetrics processor >> pure ()
observe WebSocketChurnProxy processor = replicateM_ 4 (getMetrics processor) >> pure ()

createMessages :: (IOE :> es) => Scenario -> Counters -> Word64 -> IO [Ingested es BenchMessage]
createMessages scenario counters started =
  pure [createMessage index | index <- [1 .. scenario.messageCount]]
  where
    createMessage index =
      let scheduled = started + fromIntegral ((index - 1) * scenario.arrivalIntervalMicros) * 1_000
          message = BenchMessage index scheduled (Text.replicate 4 "payload-")
          messageId = MessageId ("lifecycle-" <> Text.pack (show index))
          envelope =
            (mkEnvelope messageId message)
              { enqueuedAt = Just benchTime,
                partition = partitionFor scenario.partitions index
              }
          handle = AckHandle (recordFinalization counters message)
       in mkIngested envelope handle

recordFinalization :: (IOE :> es) => Counters -> BenchMessage -> AckDecision -> Eff es ()
recordFinalization counters message decision = liftIO $ do
  now <- getMonotonicTimeNSec
  atomicModifyIORef' counters.acknowledged (\count -> (count + 1, ()))
  atomicModifyIORef' counters.latenciesNs (\samples -> (now - message.scheduledAtNs : samples, ()))
  case decision of
    AckRetry _ -> atomicModifyIORef' counters.retried (\count -> (count + 1, ()))
    AckDeadLetter _ -> atomicModifyIORef' counters.deadLettered (\count -> (count + 1, ()))
    _ -> pure ()

decisionFor :: DecisionFixture -> Int -> AckDecision
decisionFor AllAckOk _ = AckOk
decisionFor (RetryEvery divisor) index
  | index `mod` divisor == 0 = AckRetry (RetryDelay 0)
  | otherwise = AckOk
decisionFor (DeadLetterEvery divisor) index
  | index `mod` divisor == 0 = AckDeadLetter MaxRetriesExceeded
  | otherwise = AckOk

partitionFor :: PartitionFixture -> Int -> Maybe Text
partitionFor NoPartitions _ = Nothing
partitionFor (UniformPartitions count) index = Just ("partition-" <> Text.pack (show (index `mod` count)))
partitionFor (HotKeyPartitions count) index
  | index `mod` 10 < 8 = Just "hot"
  | otherwise = Just ("partition-" <> Text.pack (show (index `mod` count)))
partitionFor HighCardinalityPartitions index = Just ("partition-" <> Text.pack (show index))

newCounters :: IO Counters
newCounters =
  Counters
    <$> newIORef 0
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef []

quantile :: Double -> [Word64] -> Word64
quantile _ [] = 0
quantile probability samples =
  let ordered = sort samples
      index = max 0 (min (length ordered - 1) (ceiling (probability * fromIntegral (length ordered)) - 1))
   in ordered !! index

delta :: (RTSStats -> Word64) -> RTSStats -> RTSStats -> Word64
delta field before after = field after - field before

deltaTime :: (RTSStats -> Int64) -> RTSStats -> RTSStats -> Word64
deltaTime field before after = fromIntegral (max 0 (field after - field before))

lifecycleResultValue :: Text -> LifecycleResult -> Value
lifecycleResultValue sampleId result@LifecycleResult {scenario} =
  object
    [ "schemaVersion" .= (1 :: Int),
      "sampleId" .= sampleId,
      "workloadVersion" .= (3 :: Int),
      "scenario" .= scenario.name,
      "configuration" .= scenarioValue scenario,
      "metrics" .= metricsValue result
    ]

scenarioValue :: Scenario -> Value
scenarioValue scenario =
  object
    [ "concurrency" .= show scenario.concurrency,
      "ordering" .= show scenario.ordering,
      "messages" .= scenario.messageCount,
      "inboxSize" .= scenario.inboxSize,
      "handlerDelayMicros" .= scenario.handlerDelayMicros,
      "arrivalIntervalMicros" .= scenario.arrivalIntervalMicros,
      "partitions" .= show scenario.partitions,
      "decisions" .= show scenario.decisions,
      "batching" .= show scenario.batching,
      "observer" .= show scenario.observer,
      "shutdown" .= show scenario.shutdown,
      "observerFidelity"
        .= case scenario.observer of
          HealthPollingProxy -> ("core-proxy; HTTP fixture belongs to EP-39" :: Text)
          WebSocketChurnProxy -> "core-proxy; WebSocket fixture belongs to EP-39"
          _ -> "core",
      "startupCycles" .= scenario.startupCycles,
      "idleBeforeFirstMessageMicros" .= scenario.idleBeforeFirstMessageMicros
    ]

metricsValue :: LifecycleResult -> Value
metricsValue result =
  let elapsedSeconds = fromIntegral result.elapsedNs / 1_000_000_000
      expectedUnits = max 1 result.expected
      throughput = fromIntegral result.completed / elapsedSeconds
      allocationPerUnit = fromIntegral result.allocatedBytes / fromIntegral expectedUnits
      cpuPercent = fromIntegral result.cpuNs / fromIntegral result.elapsedNs * 100
   in object
        [ "expected" .= result.expected,
          "completed" .= result.completed,
          "acknowledged" .= result.acknowledged,
          "retried" .= result.retried,
          "deadLettered" .= result.deadLettered,
          "throughputPerSecond" .= (throughput :: Double),
          "latencyP50Ms" .= nanosecondsToMilliseconds result.p50Ns,
          "latencyP95Ms" .= nanosecondsToMilliseconds result.p95Ns,
          "latencyP99Ms" .= nanosecondsToMilliseconds result.p99Ns,
          "shutdownLatencyMs" .= nanosecondsToMilliseconds result.shutdownNs,
          "allocatedBytesPerMessage" .= (allocationPerUnit :: Double),
          "maxLiveBytes" .= result.maxLiveBytes,
          "gcCpuMs" .= nanosecondsToMilliseconds result.gcCpuNs,
          "cpuPercent" .= (cpuPercent :: Double),
          "capabilities" .= result.capabilities,
          "retainedMemorySlopeBytesPerMinute" .= (Nothing :: Maybe Double),
          "maxRssBytes" .= (Nothing :: Maybe Word64)
        ]

nanosecondsToMilliseconds :: Word64 -> Double
nanosecondsToMilliseconds value = fromIntegral value / 1_000_000

benchTime :: UTCTime
benchTime = UTCTime (fromGregorian 2024 1 1) 0

scenarios :: [Scenario]
scenarios =
  -- The zero-delay message flows deliberately cross several 32 MiB nursery
  -- collections. Shorter v1 runs made fixed process/processor acquisition a
  -- material part of the per-message allocation result and produced the
  -- opposite allocation ordering when the same flow was extended. Startup is
  -- measured separately below, so v2 amortizes it before applying hot-path
  -- allocation and live-heap budgets.
  [ base "serial-small-inbox" Serial Unordered 50_000 16,
    base "serial-full-inbox" Serial Unordered 50_000 50_000,
    (base "serial-fixed-rate" Serial Unordered 500 16)
      { handlerDelayMicros = 500,
        arrivalIntervalMicros = 1_000
      },
    (base "ahead-uniform-keys" (Ahead 4) PartitionedInOrder 50_000 16) {partitions = UniformPartitions 16},
    (base "async-hot-key" (Async 4) PartitionedInOrder 50_000 16) {partitions = HotKeyPartitions 16},
    (base "async-high-cardinality" (Async 4) PartitionedInOrder 50_000 16) {partitions = HighCardinalityPartitions},
    (base "batch-size" (Async 4) Unordered 50_000 16) {batching = SizeBatch 100},
    (base "batch-timeout" (Async 2) Unordered 100 16)
      { batching = TimeoutBatch 1_000 10_000,
        arrivalIntervalMicros = 2_000
      },
    (base "retry-path" Serial Unordered 20_000 16) {decisions = RetryEvery 10},
    (base "dead-letter-path" Serial Unordered 20_000 16) {decisions = DeadLetterEvery 10},
    (base "idle-worker" Serial Unordered 1 1) {idleBeforeFirstMessageMicros = 1_000_000},
    (base "metrics-disabled" (Async 4) Unordered 50_000 16) {observer = NoObserver},
    (base "metrics-enabled" (Async 4) Unordered 50_000 16) {observer = MetricsPolling},
    (base "health-poll-proxy" (Async 4) Unordered 50_000 16) {observer = HealthPollingProxy},
    (base "websocket-churn-proxy" (Async 4) Unordered 50_000 16) {observer = WebSocketChurnProxy},
    (base "graceful-shutdown-drain" Serial Unordered 1_000 16)
      { handlerDelayMicros = 1_000,
        shutdown = GracefulDrainAfter 10
      },
    (base "startup-shutdown" Serial Unordered 0 1) {startupCycles = 1_000}
  ]

base :: Text -> Concurrency -> OrderingPolicy -> Int -> Int -> Scenario
base name concurrency ordering messageCount inboxSize =
  Scenario
    { name,
      concurrency,
      ordering,
      messageCount,
      inboxSize,
      handlerDelayMicros = 0,
      arrivalIntervalMicros = 0,
      partitions = NoPartitions,
      decisions = AllAckOk,
      batching = NoBatch,
      observer = NoObserver,
      shutdown = StopAfterDrain,
      startupCycles = 0,
      idleBeforeFirstMessageMicros = 0
    }
