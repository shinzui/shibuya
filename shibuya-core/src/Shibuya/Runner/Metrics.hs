-- | Metrics and state tracking for processors.
-- Provides introspection into what's happening in the system.
module Shibuya.Runner.Metrics
  ( -- * Processor State
    ProcessorState (..),
    ProcessorId (..),

    -- * In-Flight Tracking
    InFlightInfo (..),
    emptyInFlightInfo,

    -- * Stream Statistics
    StreamStats (..),
    emptyStreamStats,

    -- * Combined Metrics
    ProcessorMetrics (..),
    emptyProcessorMetrics,

    -- * Metrics Map
    MetricsMap,

    -- * Metrics Updates
    incReceived,
    incDropped,
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
emptyInFlightInfo maxConc = InFlightInfo 0 maxConc

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
    -- | Messages dropped (backpressure)
    dropped :: !Int,
    -- | Messages successfully processed
    processed :: !Int,
    -- | Messages that failed processing
    failed :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Empty stream stats.
emptyStreamStats :: StreamStats
emptyStreamStats = StreamStats 0 0 0 0

-- | Combined processor metrics.
data ProcessorMetrics = ProcessorMetrics
  { -- | Current state
    state :: !ProcessorState,
    -- | Statistics
    stats :: !StreamStats,
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
      startedAt = now
    }

-- | Map of processor IDs to their metrics.
type MetricsMap = Map ProcessorId ProcessorMetrics

-- | Increment received count.
incReceived :: StreamStats -> StreamStats
incReceived = #received %~ (+ 1)

-- | Increment dropped count.
incDropped :: StreamStats -> StreamStats
incDropped = #dropped %~ (+ 1)

-- | Increment processed count.
incProcessed :: StreamStats -> StreamStats
incProcessed = #processed %~ (+ 1)

-- | Increment failed count.
incFailed :: StreamStats -> StreamStats
incFailed = #failed %~ (+ 1)
