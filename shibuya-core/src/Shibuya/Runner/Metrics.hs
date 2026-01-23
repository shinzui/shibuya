-- | Metrics and state tracking for processors.
-- Provides introspection into what's happening in the system.
module Shibuya.Runner.Metrics
  ( -- * Processor State
    ProcessorState (..),
    ProcessorId (..),

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

import Data.Map.Strict (Map)
import Shibuya.Prelude

-- | Processor identifier.
newtype ProcessorId = ProcessorId {unProcessorId :: Text}
  deriving stock (Eq, Ord, Show, Generic)

-- | Processor runtime state.
data ProcessorState
  = -- | Waiting for messages
    Idle
  | -- | Currently processing (count, last activity time)
    Processing !Int !UTCTime
  | -- | Failed with error (error message, timestamp)
    Failed !Text !UTCTime
  | -- | Processor has been stopped
    Stopped
  deriving stock (Eq, Show, Generic)

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
