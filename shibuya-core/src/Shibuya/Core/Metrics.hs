-- | Metrics and state tracking for processors.
-- Provides introspection into what's happening in the system.
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

    -- * Metrics Map
    MetricsMap,

    -- * Metrics Updates
    incReceived,
    incProcessed,
    incFailed,
  )
where

import Data.Aeson (FromJSON (..), FromJSONKey (..), ToJSON (..), ToJSONKey (..), object, withObject, (.:))
import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Text qualified as Text
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
  | -- | Currently processing (in-flight info, last activity time)
    Processing !InFlightInfo !UTCTime
  | -- | Failed with error (error message, timestamp)
    Failed !Text !UTCTime
  | -- | Processor has been stopped
    Stopped
  deriving stock (Eq, Show, Generic)

instance ToJSON ProcessorState where
  toJSON Idle = object ["status" Aeson..= ("idle" :: Text)]
  toJSON (Processing info lastActivity) =
    object
      [ "status" Aeson..= ("processing" :: Text),
        "inFlight" Aeson..= info.inFlight,
        "maxConcurrency" Aeson..= info.maxConcurrency,
        "lastActivity" Aeson..= lastActivity
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
        pure $ Processing (InFlightInfo inFlightCount maxConc) lastActivity
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

-- | Combined processor metrics.
data ProcessorMetrics = ProcessorMetrics
  { -- | Current state
    state :: !ProcessorState,
    -- | Per-message statistics
    stats :: !StreamStats,
    -- | Batch statistics
    batch :: !BatchStats,
    -- | When the processor started
    startedAt :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Empty processor metrics.
emptyProcessorMetrics :: UTCTime -> ProcessorMetrics
emptyProcessorMetrics now =
  ProcessorMetrics
    { state = Idle,
      stats = emptyStreamStats,
      batch = emptyBatchStats,
      startedAt = now
    }

-- | Map of processor IDs to their metrics.
type MetricsMap = Map ProcessorId ProcessorMetrics

-- | Increment received count.
incReceived :: StreamStats -> StreamStats
incReceived s = s {received = s.received + 1}

-- | Increment processed count.
incProcessed :: StreamStats -> StreamStats
incProcessed s = s {processed = s.processed + 1}

-- | Increment failed count.
incFailed :: StreamStats -> StreamStats
incFailed s = s {failed = s.failed + 1}

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
