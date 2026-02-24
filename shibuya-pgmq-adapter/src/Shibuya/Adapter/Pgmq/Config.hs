-- | Configuration types for the PGMQ adapter.
module Shibuya.Adapter.Pgmq.Config
  ( -- * Main Configuration
    PgmqAdapterConfig (..),

    -- * Polling Configuration
    PollingConfig (..),

    -- * Dead-Letter Queue Configuration
    DeadLetterConfig (..),
    DeadLetterTarget (..),

    -- * Smart Constructors
    directDeadLetter,
    topicDeadLetter,

    -- * FIFO Configuration
    FifoConfig (..),
    FifoReadStrategy (..),

    -- * Prefetch Configuration
    PrefetchConfig (..),

    -- * Defaults
    defaultConfig,
    defaultPollingConfig,
    defaultPrefetchConfig,
  )
where

import Data.Int (Int32, Int64)
import Data.Time (NominalDiffTime)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Pgmq.Types (QueueName, RoutingKey)

-- | Configuration for the PGMQ adapter.
data PgmqAdapterConfig = PgmqAdapterConfig
  { -- | Name of the queue to consume from
    queueName :: !QueueName,
    -- | Visibility timeout in seconds (default: 30)
    -- Messages become invisible for this duration after being read
    visibilityTimeout :: !Int32,
    -- | Maximum number of messages to read per poll (default: 1)
    batchSize :: !Int32,
    -- | Polling configuration
    polling :: !PollingConfig,
    -- | Optional dead-letter queue configuration
    deadLetterConfig :: !(Maybe DeadLetterConfig),
    -- | Maximum retries before dead-lettering (default: 3)
    -- Based on pgmq's readCount field
    maxRetries :: !Int64,
    -- | Optional FIFO mode configuration
    fifoConfig :: !(Maybe FifoConfig),
    -- | Optional concurrent prefetch configuration
    -- When enabled, polls ahead while processing current messages
    prefetchConfig :: !(Maybe PrefetchConfig)
  }
  deriving stock (Show, Eq, Generic)

-- | Polling strategy for reading messages.
data PollingConfig
  = -- | Standard polling with sleep between reads when queue is empty
    StandardPolling
      { -- | Interval between polls when no messages are available
        pollInterval :: !NominalDiffTime
      }
  | -- | Long polling - blocks in database until messages available
    -- More efficient when queue is often empty
    LongPolling
      { -- | Maximum seconds to wait for messages (e.g., 10)
        maxPollSeconds :: !Int32,
        -- | Interval between database checks in milliseconds (e.g., 100)
        pollIntervalMs :: !Int32
      }
  deriving stock (Show, Eq, Generic)

-- | Target for dead-lettered messages.
data DeadLetterTarget
  = -- | Send directly to a specific queue
    DirectQueue !QueueName
  | -- | Route via topic pattern matching (pgmq 1.11.0+).
    -- Messages are sent using @pgmq.send_topic@ with the given routing key,
    -- allowing fan-out to multiple DLQ consumers based on their topic bindings.
    TopicRoute !RoutingKey
  deriving stock (Show, Eq, Generic)

-- | Configuration for dead-letter queue handling.
-- When a message exceeds maxRetries or receives AckDeadLetter,
-- it will be sent to the configured target.
data DeadLetterConfig = DeadLetterConfig
  { -- | Where to send dead-lettered messages
    dlqTarget :: !DeadLetterTarget,
    -- | Whether to include original message metadata in DLQ message
    includeMetadata :: !Bool
  }
  deriving stock (Show, Eq, Generic)

-- | Create a dead-letter config targeting a specific queue directly.
directDeadLetter :: QueueName -> Bool -> DeadLetterConfig
directDeadLetter queueName metadata =
  DeadLetterConfig
    { dlqTarget = DirectQueue queueName,
      includeMetadata = metadata
    }

-- | Create a dead-letter config using topic-based routing (pgmq 1.11.0+).
-- Messages are sent via @pgmq.send_topic@ and delivered to all queues
-- whose topic bindings match the routing key.
topicDeadLetter :: RoutingKey -> Bool -> DeadLetterConfig
topicDeadLetter routingKey metadata =
  DeadLetterConfig
    { dlqTarget = TopicRoute routingKey,
      includeMetadata = metadata
    }

-- | FIFO queue configuration for ordered message processing.
-- Requires pgmq 1.8.0+ with FIFO indexes.
data FifoConfig = FifoConfig
  { -- | Strategy for reading messages from FIFO queue
    readStrategy :: !FifoReadStrategy
  }
  deriving stock (Show, Eq, Generic)

-- | Strategy for reading messages from FIFO queues.
data FifoReadStrategy
  = -- | Fill batch from same message group first (SQS-like behavior)
    -- Good for: order processing, document workflows
    ThroughputOptimized
  | -- | Fair round-robin distribution across message groups
    -- Good for: multi-tenant systems, load balancing
    RoundRobin
  deriving stock (Show, Eq, Generic)

-- | Configuration for concurrent prefetching.
-- When enabled, polls the next batch while current messages are being processed.
--
-- Trade-off: Lower latency at the cost of visibility timeout pressure.
-- Prefetched messages have their visibility timeout ticking, so ensure:
-- @bufferSize * batchSize * avgProcessingTime < visibilityTimeout@
data PrefetchConfig = PrefetchConfig
  { -- | Number of batches to buffer ahead of consumption (default: 4)
    -- Higher values reduce latency but increase visibility timeout pressure
    bufferSize :: !Natural
  }
  deriving stock (Show, Eq, Generic)

-- | Default polling configuration using standard polling with 1 second interval.
defaultPollingConfig :: PollingConfig
defaultPollingConfig = StandardPolling {pollInterval = 1}

-- | Default prefetch configuration.
-- Buffers 4 batches ahead, balancing latency with visibility timeout safety.
defaultPrefetchConfig :: PrefetchConfig
defaultPrefetchConfig = PrefetchConfig {bufferSize = 4}

-- | Default adapter configuration.
-- Note: You must set 'queueName' before using.
--
-- @
-- let config = defaultConfig { queueName = myQueueName }
-- @
--
-- To enable prefetching:
--
-- @
-- let config = (defaultConfig myQueueName) { prefetchConfig = Just defaultPrefetchConfig }
-- @
defaultConfig :: QueueName -> PgmqAdapterConfig
defaultConfig name =
  PgmqAdapterConfig
    { queueName = name,
      visibilityTimeout = 30,
      batchSize = 1,
      polling = defaultPollingConfig,
      deadLetterConfig = Nothing,
      maxRetries = 3,
      fifoConfig = Nothing,
      prefetchConfig = Nothing -- Disabled by default
    }
