-- | Metrics and state tracking for processors.
-- Provides introspection into what's happening in the system.
-- Detailed accounting is opt-in through 'MetricsDetailed': a bounded synchronized
-- slot per concurrent attempt measures handler plus finalization duration and
-- publishes oldest identity/start/age. Interrupted attempts are abandoned; basic
-- handles retain counters without detail clocks or ownership brackets. Detailed
-- progress records successful acknowledgements with a bounded partition snapshot.
module Shibuya.Core.Metrics
  ( -- * Processor State
    ProcessorState (..),
    ProcessorId (..),

    -- * In-Flight Tracking
    InFlightInfo (..),
    emptyInFlightInfo,

    -- * Stream Statistics
    StreamStats (..),
    emptyStreamStats,

    -- * Batch Statistics
    BatchStats (..),
    emptyBatchStats,
    incBatchesEmitted,
    addBatchedMessages,
    incPartialFailures,
    incSizeTriggered,
    incTimeoutTriggered,
    incFlushTriggered,

    -- * Combined Metrics
    ProcessorMetrics (..),
    emptyProcessorMetrics,
    HotCounters (..),
    MetricsHandle (..),
    metricsDetailLevel,
    MetricsDetail (..),
    DetailOptions (..),
    defaultDetailOptions,
    defaultMetricsDetail,
    LatencyBucket (..),
    LatencySummary (..),
    OldestInFlight (..),
    ProgressSnapshot (..),
    recordAcknowledgedCursor,
    latencyBucketBoundsSeconds,
    latencyBucketLabels,
    InFlightSlots,
    claimInFlightSlot,
    releaseInFlightSlot,
    abandonInFlightSlot,
    slotMisses,
    newMetricsHandleWith,
    newMetricsHandleWithClockAndDetail,
    newMetricsHandle,
    newMetricsHandleWithClock,
    sampleMetrics,
    markPaused,
    markResumed,
    markPausedSTM,
    markResumedSTM,
    incrementReceived,
    beginProcessing,
    AckDecisionMetric (..),
    finishProcessing,
    finishFinalizationFailure,
    BatchTriggerMetric (..),
    recordBatchOutcomeMetrics,

    -- * Metrics Map
    MetricsMap,

    -- * Metrics Updates
    incReceived,
    incProcessed,
    incFailed,
  )
where

import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar, readMVar)
import Control.Concurrent.STM (STM, TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (mask_)
import Control.Monad (void, when)
import Data.Aeson (FromJSON (..), FromJSONKey (..), ToJSON (..), ToJSONKey (..), object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Atomics.Counter (AtomicCounter, incrCounter, readCounter)
import Data.Atomics.Counter qualified as Counter
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef, writeIORef)
import Data.IntMap.Strict qualified as IntMap
import Data.List (minimumBy)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Shibuya.Core.Types (Cursor, MessageId)
import Shibuya.Prelude

-- | Processor identifier.
newtype ProcessorId = ProcessorId {unProcessorId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON, ToJSONKey, FromJSONKey)

-- | Tracks concurrent in-flight messages.
data InFlightInfo = InFlightInfo
  { -- | Currently processing count
    inFlight :: !Int,
    -- | Configured max concurrency (1 for Serial)
    maxConcurrency :: !Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON InFlightInfo where
  toJSON info =
    object
      [ "inFlight" Aeson..= info.inFlight,
        "maxConcurrency" Aeson..= info.maxConcurrency
      ]

instance FromJSON InFlightInfo where
  parseJSON = withObject "InFlightInfo" $ \v ->
    InFlightInfo
      <$> v .: "inFlight"
      <*> v .: "maxConcurrency"

-- | Create empty in-flight info with given max concurrency.
emptyInFlightInfo :: Int -> InFlightInfo
emptyInFlightInfo = InFlightInfo 0

-- | Processor runtime state.
data ProcessorState
  = -- | Waiting for messages
    Idle
  | -- | Currently processing (in-flight info, sampled burst start, sampled last progress)
    Processing !InFlightInfo !UTCTime !UTCTime
  | -- | Intake paused (live in-flight info, pause time, sampled last progress)
    Paused !InFlightInfo !UTCTime !UTCTime
  | -- | Failed with error (error message, timestamp)
    Failed !Text !UTCTime
  | -- | Processor has been stopped
    Stopped
  deriving stock (Eq, Show, Generic)

instance ToJSON ProcessorState where
  toJSON Idle = object ["status" Aeson..= ("idle" :: Text)]
  toJSON (Processing info lastActivity lastProgress) =
    object
      [ "status" Aeson..= ("processing" :: Text),
        "inFlight" Aeson..= info.inFlight,
        "maxConcurrency" Aeson..= info.maxConcurrency,
        "lastActivity" Aeson..= lastActivity,
        "lastProgress" Aeson..= lastProgress
      ]
  toJSON (Paused info pausedAt lastProgress) =
    object
      [ "status" Aeson..= ("paused" :: Text),
        "inFlight" Aeson..= info.inFlight,
        "maxConcurrency" Aeson..= info.maxConcurrency,
        "pausedAt" Aeson..= pausedAt,
        "lastProgress" Aeson..= lastProgress
      ]
  toJSON (Failed err timestamp) =
    object
      [ "status" Aeson..= ("failed" :: Text),
        "error" Aeson..= err,
        "timestamp" Aeson..= timestamp
      ]
  toJSON Stopped = object ["status" Aeson..= ("stopped" :: Text)]

instance FromJSON ProcessorState where
  parseJSON = withObject "ProcessorState" $ \v -> do
    status <- v .: "status"
    case status :: Text of
      "idle" -> pure Idle
      "processing" -> do
        inFlightCount <- v .: "inFlight"
        maxConc <- v .: "maxConcurrency"
        lastActivity <- v .: "lastActivity"
        lastProgress <- v .:? "lastProgress"
        pure $ Processing (InFlightInfo inFlightCount maxConc) lastActivity (fromMaybe lastActivity lastProgress)
      "paused" -> Paused <$> (InFlightInfo <$> v .: "inFlight" <*> v .: "maxConcurrency") <*> v .: "pausedAt" <*> v .: "lastProgress"
      "failed" -> Failed <$> v .: "error" <*> v .: "timestamp"
      "stopped" -> pure Stopped
      other -> fail $ "Unknown processor state: " <> Text.unpack other

-- | Stream statistics.
data StreamStats = StreamStats
  { -- | Messages received from stream
    received :: !Int,
    -- | Messages successfully processed
    processed :: !Int,
    -- | Messages that failed processing
    failed :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Empty stream stats.
emptyStreamStats :: StreamStats
emptyStreamStats = StreamStats 0 0 0

-- | Batch-processing statistics, tracked alongside per-message stream stats.
data BatchStats = BatchStats
  { -- | Number of batches emitted and executed.
    batchesEmitted :: !Int,
    -- | Total messages across all emitted batches.
    batchedMessages :: !Int,
    -- | Batches with a genuine partial failure: the handler returned normally
    -- and named at least one message in its decision map with a failing
    -- decision (dead-letter or retry) while acking the rest. Counted per batch,
    -- not per message, so it does not double-count the per-message 'failed'
    -- counter.
    partialFailures :: !Int,
    -- | Batches emitted because they reached the configured size.
    sizeTriggered :: !Int,
    -- | Batches emitted because their timeout elapsed.
    timeoutTriggered :: !Int,
    -- | Batches emitted because the processor was draining (flush).
    flushTriggered :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Empty batch stats (all zero).
emptyBatchStats :: BatchStats
emptyBatchStats = BatchStats 0 0 0 0 0 0

-- | Basic accounting is the default. Detailed timing includes handler execution
-- and all finalization retries, once per message attempt or emitted batch.
data MetricsDetail = MetricsBasic | MetricsDetailed !DetailOptions
  deriving stock (Eq, Show, Generic)

-- | Bounds for optional detail. Zero partitions reserves latest-only progress.
data DetailOptions = DetailOptions {maxTrackedPartitions :: !Int}
  deriving stock (Eq, Show, Generic)

defaultDetailOptions :: DetailOptions
defaultDetailOptions = DetailOptions 256

defaultMetricsDetail :: MetricsDetail
defaultMetricsDetail = MetricsBasic

data LatencyBucket = LatencyBucket {le :: !Double, count :: !Integer}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data LatencySummary = LatencySummary
  {count :: !Integer, sumSeconds :: !Double, buckets :: ![LatencyBucket]}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data OldestInFlight = OldestInFlight
  {messageId :: !MessageId, startedAt :: !UTCTime, ageSeconds :: !Double}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Last successful finalization recorded, with bounded partition detail.
-- Cursors are opaque; concurrent completion order need not be source order.
data ProgressSnapshot = ProgressSnapshot
  { latest :: !(Maybe Cursor),
    partitions :: !(Map Text Cursor),
    truncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ProgressSnapshot where
  toJSON = Aeson.genericToJSON omitNothingOptions

instance FromJSON ProgressSnapshot where
  parseJSON = Aeson.genericParseJSON omitNothingOptions

data ProgressTable = ProgressTable
  {snapshot :: !(TVar ProgressSnapshot), maxPartitions :: !Int}

-- | Record only after successful AckOk or AckDeadLetter finalization.
-- Missing cursors and basic handles do not enter STM.
recordAcknowledgedCursor :: MetricsHandle -> Maybe Text -> Maybe Cursor -> IO ()
recordAcknowledgedCursor handle partition cursor = case (handle.progressTable, cursor) of
  (Just table, Just position) -> atomically $ modifyTVar' table.snapshot $ \old ->
    let (partitions, truncated) = case partition of
          Nothing -> (old.partitions, old.truncated)
          Just key
            | Map.member key old.partitions || Map.size old.partitions < table.maxPartitions ->
                (Map.insert key position old.partitions, old.truncated)
            | otherwise -> (old.partitions, True)
     in ProgressSnapshot (Just position) partitions truncated
  _ -> pure ()

latencyBucketBoundsSeconds :: [Double]
latencyBucketBoundsSeconds = [0.0001, 0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60]

latencyBucketBoundsNs :: [Word64]
latencyBucketBoundsNs = [100_000, 250_000, 500_000, 1_000_000, 2_500_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000, 100_000_000, 250_000_000, 500_000_000, 1_000_000_000, 2_500_000_000, 5_000_000_000, 10_000_000_000, 30_000_000_000, 60_000_000_000]

latencyBucketLabels :: [Text]
latencyBucketLabels = ["0.0001", "0.00025", "0.0005", "0.001", "0.0025", "0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5", "10", "30", "60", "+Inf"]

-- Each slot is also a histogram shard. Its lock is never held across user code.
data DetailSlot = DetailSlot
  { start :: !(Maybe (MessageId, Word64)),
    observations :: !Integer,
    totalNs :: !Integer,
    bins :: !(IntMap.IntMap Integer)
  }

data InFlightSlots = InFlightSlots
  {cells :: ![MVar DetailSlot], misses :: !(IORef Integer)}

-- | Diagnostic exhaustion count. Supported runners must never miss a slot.
slotMisses :: MetricsHandle -> IO Integer
slotMisses handle = maybe (pure 0) (readIORef . (.misses)) handle.slots

-- | Claim a bounded slot, publishing identity and start under the same lock.
-- Callers must mask ownership transfer until they install exception cleanup.
claimInFlightSlot :: MetricsHandle -> MessageId -> IO Int
claimInFlightSlot handle messageId = case handle.slots of
  Nothing -> pure (-1)
  Just table -> mask_ $ do
    now <- handle.progressClock
    let claim _ [] = do
          atomicModifyIORef' table.misses (\n -> (n + 1, ()))
          pure (-1)
        claim index (cell : rest) = do
          owned <- modifyMVar cell $ \slot -> case slot.start of
            Nothing -> pure (slot {start = Just (messageId, now)}, True)
            Just _ -> pure (slot, False)
          if owned then pure index else claim (index + 1) rest
    claim 0 table.cells
{-# INLINE claimInFlightSlot #-}

-- | Complete one attempt, including finalization. Interrupted attempts instead
-- use 'abandonInFlightSlot' and contribute no completed observation.
releaseInFlightSlot :: MetricsHandle -> Int -> IO ()
releaseInFlightSlot handle index = withSlot handle index $ \cell -> mask_ $ do
  now <- handle.progressClock
  modifyMVar_ cell $ \slot -> case slot.start of
    Nothing -> pure slot
    Just (_, began) -> do
      let duration = if now >= began then now - began else 0
          bucketIndex = length (takeWhile (< duration) latencyBucketBoundsNs)
      pure $!
        DetailSlot
          Nothing
          (slot.observations + 1)
          (slot.totalNs + toInteger duration)
          (IntMap.insertWith (+) bucketIndex 1 slot.bins)

abandonInFlightSlot :: MetricsHandle -> Int -> IO ()
abandonInFlightSlot handle index = withSlot handle index $ \cell ->
  modifyMVar_ cell $ \slot -> pure $! slot {start = Nothing}

withSlot :: MetricsHandle -> Int -> (MVar DetailSlot -> IO ()) -> IO ()
withSlot handle index action
  | index < 0 = pure ()
  | otherwise = case handle.slots of
      Nothing -> pure ()
      Just table -> case drop index table.cells of
        cell : _ -> action cell
        [] -> pure ()

-- Copy each strict shard under its lock, format only after releasing it.
-- Sampling across slots is best effort; identity and timestamp always agree.
sampleDetail :: MetricsHandle -> IO (Maybe LatencySummary, Maybe OldestInFlight)
sampleDetail handle = case handle.slots of
  Nothing -> pure (Nothing, Nothing)
  Just table -> do
    copies <- mapM readMVar table.cells
    let observations = sum (map (.observations) copies)
        totalNs = sum (map (.totalNs) copies)
        bins = IntMap.unionsWith (+) (map (.bins) copies)
        cumulative = drop 1 (scanl (+) 0 [IntMap.findWithDefault 0 i bins | i <- [0 .. 17]])
        summary =
          if observations == 0
            then Nothing
            else
              Just
                ( LatencySummary
                    observations
                    (fromInteger totalNs / 1_000_000_000)
                    (zipWith LatencyBucket latencyBucketBoundsSeconds cumulative)
                )
        starts = [start | DetailSlot {start = Just start} <- copies]
    oldest <- case starts of
      [] -> pure Nothing
      _ -> do
        now <- handle.progressClock
        let (messageId, began) = minimumBy (comparing snd) starts
            elapsed = if now >= began then now - began else 0
        pure $
          Just
            ( OldestInFlight
                messageId
                (monotonicToUTC handle began)
                (fromIntegral elapsed / 1_000_000_000)
            )
    pure (summary, oldest)

-- | Combined processor metrics.
data ProcessorMetrics = ProcessorMetrics
  { -- | Current state
    state :: !ProcessorState,
    -- | Per-message statistics
    stats :: !StreamStats,
    -- | Batch statistics
    batch :: !BatchStats,
    -- | When the processor started
    startedAt :: !UTCTime,
    latency :: !(Maybe LatencySummary),
    oldestInFlight :: !(Maybe OldestInFlight),
    progress :: !(Maybe ProgressSnapshot)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON ProcessorMetrics where
  toJSON = Aeson.genericToJSON omitNothingOptions

instance FromJSON ProcessorMetrics where
  parseJSON = Aeson.genericParseJSON omitNothingOptions

omitNothingOptions :: Aeson.Options
omitNothingOptions = Aeson.defaultOptions {Aeson.omitNothingFields = True}

-- | Empty processor metrics.
emptyProcessorMetrics :: UTCTime -> ProcessorMetrics
emptyProcessorMetrics now =
  ProcessorMetrics
    { state = Idle,
      stats = emptyStreamStats,
      batch = emptyBatchStats,
      startedAt = now,
      latency = Nothing,
      oldestInFlight = Nothing,
      progress = Nothing
    }

-- | Map of processor IDs to their metrics.
type MetricsMap = Map ProcessorId ProcessorMetrics

-- | Hot per-message counters for one processor.
--
-- These counters are updated by fetch-and-add operations on the message hot
-- path. The colder 'ProcessorMetrics' TVar inside 'MetricsHandle' stores state,
-- batch counters, and metadata that change less frequently.
data HotCounters = HotCounters
  { received :: !AtomicCounter,
    processed :: !AtomicCounter,
    failed :: !AtomicCounter,
    inFlight :: !AtomicCounter
  }

-- | Write-side metrics handle for one processor.
data MetricsHandle = MetricsHandle
  { hot :: !HotCounters,
    maxConcurrencyRef :: !(IORef Int),
    burstStartedRef :: !(IORef UTCTime),
    lastProgressRef :: !(IORef Word64),
    progressOriginNs :: !Word64,
    progressOriginTime :: !UTCTime,
    progressClock :: !(IO Word64),
    lastObservedProgress :: !(IORef (Int, Int, Int)),
    stateActiveRef :: !(IORef Bool),
    detail :: !MetricsDetail,
    slots :: !(Maybe InFlightSlots),
    progressTable :: !(Maybe ProgressTable),
    cold :: !(TVar ProcessorMetrics)
  }

-- | Read the configured level once, outside the processing loop. Keep this
-- accessor opaque: exposing the record match lets GHC carry the individual
-- counter references through each basic worker closure instead of one handle.
{-# OPAQUE metricsDetailLevel #-}
metricsDetailLevel :: MetricsHandle -> MetricsDetail
metricsDetailLevel handle = handle.detail

newMetricsHandle :: UTCTime -> IO MetricsHandle
newMetricsHandle = newMetricsHandleWithClock getMonotonicTimeNSec

-- | Create a metrics handle with an injectable monotonic clock. The custom
-- clock is intended for deterministic tests; production callers should use
-- 'newMetricsHandle'.
newMetricsHandleWithClock :: IO Word64 -> UTCTime -> IO MetricsHandle
newMetricsHandleWithClock clock = newMetricsHandleWithClockAndDetail clock MetricsBasic 1

newMetricsHandleWith :: MetricsDetail -> Int -> UTCTime -> IO MetricsHandle
newMetricsHandleWith = newMetricsHandleWithClockAndDetail getMonotonicTimeNSec

newMetricsHandleWithClockAndDetail :: IO Word64 -> MetricsDetail -> Int -> UTCTime -> IO MetricsHandle
newMetricsHandleWithClockAndDetail clock detail maxConcurrency now = do
  when (maxConcurrency < 1) $ ioError (userError "metrics concurrency must be positive")
  case detail of
    MetricsDetailed options
      | options.maxTrackedPartitions < 0 ->
          ioError (userError "maxTrackedPartitions must be nonnegative")
    _ -> pure ()
  slots <- case detail of
    MetricsBasic -> pure Nothing
    MetricsDetailed _ -> do
      cells <- mapM (const (newMVar (DetailSlot Nothing 0 0 IntMap.empty))) [1 .. maxConcurrency]
      misses <- newIORef 0
      pure (Just (InFlightSlots cells misses))
  progressOriginNs <- clock
  progressTable <- case detail of
    MetricsBasic -> pure Nothing
    MetricsDetailed options -> do
      snapshot <- newTVarIO (ProgressSnapshot Nothing Map.empty False)
      pure (Just (ProgressTable snapshot options.maxTrackedPartitions))
  received <- Counter.newCounter 0
  processed <- Counter.newCounter 0
  failed <- Counter.newCounter 0
  inFlight <- Counter.newCounter 0
  maxConcurrencyRef <- newIORef 1
  burstStartedRef <- newIORef now
  lastProgressRef <- newIORef progressOriginNs
  lastObservedProgress <- newIORef (0, 0, 0)
  stateActiveRef <- newIORef False
  cold <- newTVarIO (emptyProcessorMetrics now)
  pure
    MetricsHandle
      { hot =
          HotCounters
            { received = received,
              processed = processed,
              failed = failed,
              inFlight = inFlight
            },
        maxConcurrencyRef = maxConcurrencyRef,
        burstStartedRef = burstStartedRef,
        lastProgressRef = lastProgressRef,
        progressOriginNs = progressOriginNs,
        progressOriginTime = now,
        progressClock = clock,
        lastObservedProgress = lastObservedProgress,
        stateActiveRef = stateActiveRef,
        detail = detail,
        slots = slots,
        progressTable = progressTable,
        cold = cold
      }

sampleMetrics :: MetricsHandle -> IO ProcessorMetrics
sampleMetrics handle = do
  coldSnapshot <- readTVarIO handle.cold
  received <- readCounter handle.hot.received
  processed <- readCounter handle.hot.processed
  failed <- readCounter handle.hot.failed
  inFlight <- readCounter handle.hot.inFlight
  maxConcurrency <- readIORef handle.maxConcurrencyRef
  observeProgress handle processed failed inFlight
  burstStartedAt <- readIORef handle.burstStartedRef
  lastProgressNs <- readIORef handle.lastProgressRef
  let lastProgressAt = monotonicToUTC handle lastProgressNs
  let sampledStats =
        StreamStats
          { received = received,
            processed = processed,
            failed = failed
          }
      sampledState = case coldSnapshot.state of
        Failed err timestamp -> Failed err timestamp
        Stopped -> Stopped
        Paused _ since _ -> Paused (InFlightInfo inFlight maxConcurrency) since lastProgressAt
        _ | inFlight > 0 -> Processing (InFlightInfo inFlight maxConcurrency) burstStartedAt lastProgressAt
        _ -> Idle
  (latency, oldestInFlight) <- sampleDetail handle
  progress <- case handle.progressTable of
    Nothing -> pure Nothing
    Just table -> do
      snapshot <- readTVarIO table.snapshot
      pure $ case snapshot.latest of
        Nothing -> Nothing
        Just _ -> Just snapshot
  pure coldSnapshot {state = sampledState, stats = sampledStats, latency, oldestInFlight, progress}

-- | Publish pause intent without resetting the last-progress clock.
markPaused :: MetricsHandle -> UTCTime -> IO ()
markPaused handle = atomically . markPausedSTM handle

markPausedSTM :: MetricsHandle -> UTCTime -> STM ()
markPausedSTM handle since = modifyTVar' handle.cold $ \m -> case m.state of
  Failed {} -> m
  Stopped -> m
  Paused {} -> m
  _ -> m {state = Paused (InFlightInfo 0 0) since since}

-- | Clear only a pause; terminal and failure observations retain precedence.
markResumed :: MetricsHandle -> IO ()
markResumed = atomically . markResumedSTM

markResumedSTM :: MetricsHandle -> STM ()
markResumedSTM handle = modifyTVar' handle.cold $ \m -> case m.state of
  Paused {} -> m {state = Idle}
  _ -> m

incrementReceived :: MetricsHandle -> IO ()
incrementReceived handle =
  void $ incrCounter 1 handle.hot.received

beginProcessing :: MetricsHandle -> Int -> IO Int
beginProcessing handle maxConcurrency = do
  currentInflight <- incrCounter 1 handle.hot.inFlight
  when (currentInflight == 1) $ do
    writeIORef handle.maxConcurrencyRef maxConcurrency
    writeIORef handle.stateActiveRef True
  pure currentInflight

finishProcessing :: MetricsHandle -> Either Text AckDecisionMetric -> IO ()
finishProcessing handle result = do
  case result of
    Right CountProcessed -> void $ incrCounter 1 handle.hot.processed
    Right CountFailed -> void $ incrCounter 1 handle.hot.failed
    Right CountNeither -> pure ()
    Right (CountHalt _) -> pure ()
    Left _ -> void $ incrCounter 1 handle.hot.failed
  remaining <- decrementCounterFloorZero handle.hot.inFlight
  when (remaining == 0) $ writeIORef handle.stateActiveRef False
  case result of
    Left failureText -> setFailed failureText
    Right (CountHalt reasonText) -> setFailed reasonText
    _ -> pure ()
  where
    setFailed failureText = do
      now <- getCurrentTime
      writeIORef handle.stateActiveRef False
      atomically $
        modifyTVar' handle.cold $ \m ->
          m {state = Failed failureText now}

finishFinalizationFailure :: MetricsHandle -> Text -> IO ()
finishFinalizationFailure handle failureText =
  finishProcessing handle (Left failureText)

data AckDecisionMetric
  = CountProcessed
  | CountFailed
  | CountNeither
  | CountHalt !Text

recordBatchOutcomeMetrics ::
  MetricsHandle ->
  BatchTriggerMetric ->
  Int ->
  Bool ->
  Bool ->
  [AckDecisionMetric] ->
  Maybe Text ->
  IO ()
recordBatchOutcomeMetrics handle trigger size handlerThrew partialInc decisions firstHalt = do
  let (processedDelta, failedDelta) =
        foldl'
          ( \(processedAcc, failedAcc) decision ->
              if handlerThrew
                then (processedAcc, failedAcc + 1)
                else case decision of
                  CountProcessed -> (processedAcc + 1, failedAcc)
                  CountFailed -> (processedAcc, failedAcc + 1)
                  CountNeither -> (processedAcc, failedAcc)
                  CountHalt _ -> (processedAcc, failedAcc)
          )
          (0, 0)
          decisions
  when (processedDelta /= 0) $
    void $
      incrCounter processedDelta handle.hot.processed
  when (failedDelta /= 0) $
    void $
      incrCounter failedDelta handle.hot.failed
  remaining <- decrementCounterFloorZero handle.hot.inFlight
  now <- getCurrentTime
  atomically $
    modifyTVar' handle.cold $ \m ->
      let newState = case firstHalt of
            Just reasonText -> Failed reasonText now
            Nothing -> case m.state of
              Failed {} -> m.state
              Stopped -> Stopped
              _ -> m.state
          newBatch =
            incTriggerMetric trigger
              . (if partialInc then incPartialFailures else id)
              . addBatchedMessages size
              . incBatchesEmitted
              $ m.batch
       in m {state = newState, batch = newBatch}
  case firstHalt of
    Just _ -> writeIORef handle.stateActiveRef False
    Nothing -> when (remaining == 0) $ writeIORef handle.stateActiveRef False

observeProgress :: MetricsHandle -> Int -> Int -> Int -> IO ()
observeProgress handle processed failed inFlight = do
  let current = (processed, failed, inFlight)
  previous@(_, _, previousInFlight) <- readIORef handle.lastObservedProgress
  when (current /= previous) $ do
    progressNs <- handle.progressClock
    atomicWriteIORef handle.lastProgressRef progressNs
    atomicWriteIORef handle.lastObservedProgress current
    -- Burst boundaries are sampled observations: an observed idle-to-active
    -- transition restamps lastActivity, while a continuously active processor
    -- only advances lastProgress. An idle gap wholly between samples cannot
    -- affect stuck detection because changed counters still advance progress.
    when (inFlight > 0 && previousInFlight == 0) $
      atomicWriteIORef handle.burstStartedRef (monotonicToUTC handle progressNs)

monotonicToUTC :: MetricsHandle -> Word64 -> UTCTime
monotonicToUTC handle progressNs =
  let elapsedNs
        | progressNs >= handle.progressOriginNs = progressNs - handle.progressOriginNs
        | otherwise = 0
      elapsedSeconds = fromIntegral elapsedNs / 1_000_000_000
   in addUTCTime elapsedSeconds handle.progressOriginTime

decrementCounterFloorZero :: AtomicCounter -> IO Int
decrementCounterFloorZero counter = do
  remaining <- incrCounter (-1) counter
  if remaining >= 0
    then pure remaining
    else do
      -- Underflow means a caller completed work it did not begin. Repair the
      -- decrement so externally sampled in-flight never remains below zero;
      -- the valid hot path stays one fetch-and-add operation.
      Counter.incrCounter_ 1 counter
      pure 0

data BatchTriggerMetric
  = CountTriggerSize
  | CountTriggerTimeout
  | CountTriggerFlush

incTriggerMetric :: BatchTriggerMetric -> BatchStats -> BatchStats
incTriggerMetric CountTriggerSize = incSizeTriggered
incTriggerMetric CountTriggerTimeout = incTimeoutTriggered
incTriggerMetric CountTriggerFlush = incFlushTriggered

-- | Increment received count.
incReceived :: StreamStats -> StreamStats
incReceived StreamStats {received, processed, failed} =
  StreamStats {received = received + 1, processed = processed, failed = failed}

-- | Increment processed count.
incProcessed :: StreamStats -> StreamStats
incProcessed StreamStats {received, processed, failed} =
  StreamStats {received = received, processed = processed + 1, failed = failed}

-- | Increment failed count.
incFailed :: StreamStats -> StreamStats
incFailed StreamStats {received, processed, failed} =
  StreamStats {received = received, processed = processed, failed = failed + 1}

-- | Increment the emitted-batch counter.
incBatchesEmitted :: BatchStats -> BatchStats
incBatchesEmitted s = s {batchesEmitted = s.batchesEmitted + 1}

-- | Add to the total batched-messages counter.
addBatchedMessages :: Int -> BatchStats -> BatchStats
addBatchedMessages n s = s {batchedMessages = s.batchedMessages + n}

-- | Increment the partial-failure batch counter.
incPartialFailures :: BatchStats -> BatchStats
incPartialFailures s = s {partialFailures = s.partialFailures + 1}

-- | Increment the size-trigger counter.
incSizeTriggered :: BatchStats -> BatchStats
incSizeTriggered s = s {sizeTriggered = s.sizeTriggered + 1}

-- | Increment the timeout-trigger counter.
incTimeoutTriggered :: BatchStats -> BatchStats
incTimeoutTriggered s = s {timeoutTriggered = s.timeoutTriggered + 1}

-- | Increment the flush-trigger counter.
incFlushTriggered :: BatchStats -> BatchStats
incFlushTriggered s = s {flushTriggered = s.flushTriggered + 1}
