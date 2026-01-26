-- | Configuration types for the PGMQ adapter.
module Shibuya.Adapter.Pgmq.Config
  ( -- * Main Configuration
    PgmqAdapterConfig (..),

    -- * Polling Configuration
    PollingConfig (..),

    -- * Dead-Letter Queue Configuration
    DeadLetterConfig (..),

    -- * FIFO Configuration
    FifoConfig (..),
    FifoReadStrategy (..),

    -- * Defaults
    defaultConfig,
    defaultPollingConfig,
  )
where

import Data.Int (Int32, Int64)
import Data.Time (NominalDiffTime)
import GHC.Generics (Generic)
import Pgmq.Types (QueueName)

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
    fifoConfig :: !(Maybe FifoConfig)
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

-- | Configuration for dead-letter queue handling.
-- When a message exceeds maxRetries or receives AckDeadLetter,
-- it will be sent to the configured DLQ.
data DeadLetterConfig = DeadLetterConfig
  { -- | Name of the dead-letter queue
    dlqQueueName :: !QueueName,
    -- | Whether to include original message metadata in DLQ message
    includeMetadata :: !Bool
  }
  deriving stock (Show, Eq, Generic)

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

-- | Default polling configuration using standard polling with 1 second interval.
defaultPollingConfig :: PollingConfig
defaultPollingConfig = StandardPolling {pollInterval = 1}

-- | Default adapter configuration.
-- Note: You must set 'queueName' before using.
--
-- @
-- let config = defaultConfig { queueName = myQueueName }
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
      fifoConfig = Nothing
    }
