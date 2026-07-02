-- | Public vocabulary for batch processing.
--
-- This module defines the types a user needs to opt a processor into batching:
-- the batch handler, its configuration, the grouping key, and the batch
-- acknowledgement result. It adds no runtime behavior; the accumulation engine
-- and execution stage live in the internal @Shibuya.Internal.Runner.*@ modules.
--
-- == Acknowledgement decision contract
--
-- Given an emitted batch and the 'BatchAck' a 'BatchHandler' returns, the
-- framework resolves one 'AckDecision' for /every/ message in its own
-- retained batch list. For each retained message it looks the message's
-- 'MessageId' up in 'decisions'; if the id is absent it uses 'fallback'. The
-- handler's return value only /supplies decisions/ — it never drives which
-- messages are acked. Consequently decision resolution is complete and
-- deterministic regardless of what the handler returns (wrong length,
-- reordered, missing ids all degrade gracefully to the fallback). This
-- requires 'MessageId's to be unique within a batch, which holds for every
-- real adapter and the mock adapter. The runtime execution stage applies each
-- resolved decision through the message's idempotent @AckHandle.finalize@ with
-- bounded retries.
module Shibuya.Batch
  ( -- * Grouping key
    BatchKey (..),
    defaultBatchKey,

    -- * Emission trigger
    BatchTrigger (..),

    -- * Batch metadata
    BatchInfo (..),

    -- * Configuration
    BatchConfig (..),
    defaultBatchConfig,
    BatchConfigError (..),
    validateBatchConfig,

    -- * Handler
    BatchHandler,

    -- * Acknowledgement result
    BatchAck (..),
    ackAllOk,
    ackAll,
    ackExcept,
    withFallback,
    failMessages,
  )
where

import Control.DeepSeq (NFData)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.String (IsString)
import Effectful (Eff)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason)
import Shibuya.Core.Ingested (Message)
import Shibuya.Core.Types (Envelope, MessageId)
import Shibuya.Prelude

-- | Groups messages into independent sub-batches within one processor.
-- Messages sharing a key accumulate together; each key has its own size
-- counter and timeout. Compute one per message via 'BatchConfig'\'s 'batchKey'.
newtype BatchKey = BatchKey {unBatchKey :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString)
  deriving anyclass (NFData)

-- | The key used when a configuration does not distinguish sub-batches.
defaultBatchKey :: BatchKey
defaultBatchKey = BatchKey "default"

-- | Why the framework emitted a batch.
data BatchTrigger
  = -- | Reached the configured 'batchSize'.
    TriggerSize
  | -- | 'batchTimeout' elapsed since the batch's first message arrived.
    TriggerTimeout
  | -- | The processor is draining/shutting down; a partial batch was flushed.
    TriggerFlush
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Metadata about an emitted batch, passed to the 'BatchHandler' alongside
-- the messages.
data BatchInfo = BatchInfo
  { -- | The key all messages in this batch share.
    batchKey :: !BatchKey,
    -- | How many messages are in this batch (always >= 1).
    size :: !Int,
    -- | Why this batch was emitted.
    trigger :: !BatchTrigger,
    -- | Partition of the batch's first message, if the envelope had one.
    partition :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Configuration for a batching processor.
--
-- @es@ is the effect stack and @msg@ the payload type, matching the
-- 'BatchHandler' this config is paired with.
data BatchConfig es msg = BatchConfig
  { -- | Emit a batch once it holds this many messages. Must be >= 1.
    batchSize :: !Int,
    -- | Emit a batch this long after its first message arrives, even if it
    -- has not reached 'batchSize'. Must be > 0.
    batchTimeout :: !NominalDiffTime,
    -- | Compute a message's sub-batch key from its envelope. Use
    -- @const 'defaultBatchKey'@ for a single undivided batch.
    batchKey :: !(Envelope msg -> BatchKey),
    -- | How often the timeout ticker scans for timed-out batches. 'Nothing'
    -- means "use 'batchTimeout'". Flush latency is bounded by this interval.
    -- Must be > 0 when 'Just'.
    tickInterval :: !(Maybe NominalDiffTime)
  }

-- | Batch of at most 100, flushed after 1 second, one undivided sub-batch,
-- ticker granularity equal to the timeout. Matches Broadway's defaults
-- (@batch_size: 100@, @batch_timeout: 1000@ ms).
defaultBatchConfig :: BatchConfig es msg
defaultBatchConfig =
  BatchConfig
    { batchSize = 100,
      batchTimeout = 1,
      batchKey = const defaultBatchKey,
      tickInterval = Nothing
    }

-- | A batch handler processes a whole batch at once and returns how to
-- acknowledge it. Unlike 'Shibuya.Handler.Handler' (one message -> one
-- decision), a batch handler receives every message in the batch plus its
-- 'BatchInfo', and returns a single 'BatchAck' describing per-message
-- outcomes. See the module haddock for the acknowledgement decision contract.
type BatchHandler es msg = BatchInfo -> NonEmpty (Message es msg) -> Eff es BatchAck

-- | How to acknowledge every message in a batch. The framework resolves each
-- retained message's decision by looking its 'MessageId' up in 'decisions', or
-- by using 'fallback' if absent. The execution stage applies those decisions to
-- the messages' idempotent finalizers. See the module haddock.
data BatchAck = BatchAck
  { -- | Per-message overrides, keyed by 'MessageId'.
    decisions :: !(Map MessageId AckDecision),
    -- | Decision for any message not present in 'decisions'.
    fallback :: !AckDecision
  }
  deriving stock (Show, Generic)

-- | Acknowledge every message as successfully processed. The common case.
ackAllOk :: BatchAck
ackAllOk = BatchAck Map.empty AckOk

-- | Apply one decision to every message in the batch.
ackAll :: AckDecision -> BatchAck
ackAll = BatchAck Map.empty

-- | Acknowledge everything 'AckOk' except the listed messages, which get their
-- given decisions. Use for partial failure within an otherwise-successful batch.
ackExcept :: [(MessageId, AckDecision)] -> BatchAck
ackExcept overrides = BatchAck (Map.fromList overrides) AckOk

-- | Give the listed messages their decisions and everything else @fb@.
withFallback :: AckDecision -> [(MessageId, AckDecision)] -> BatchAck
withFallback fb overrides = BatchAck (Map.fromList overrides) fb

-- | Dead-letter the listed messages (with reasons) and acknowledge the rest OK.
failMessages :: [(MessageId, DeadLetterReason)] -> BatchAck
failMessages fs =
  BatchAck (Map.fromList [(mid, AckDeadLetter r) | (mid, r) <- fs]) AckOk

-- | Why a 'BatchConfig' is invalid.
data BatchConfigError
  = BatchSizeNotPositive !Int
  | BatchTimeoutNotPositive !NominalDiffTime
  | TickIntervalNotPositive !NominalDiffTime
  deriving stock (Eq, Show, Generic)

-- | Validate a batch configuration. 'batchSize' must be >= 1, 'batchTimeout'
-- must be > 0, and 'tickInterval' (when set) must be > 0.
validateBatchConfig :: BatchConfig es msg -> Either BatchConfigError ()
validateBatchConfig cfg
  | cfg.batchSize < 1 = Left (BatchSizeNotPositive cfg.batchSize)
  | cfg.batchTimeout <= 0 = Left (BatchTimeoutNotPositive cfg.batchTimeout)
  | Just t <- cfg.tickInterval, t <= 0 = Left (TickIntervalNotPositive t)
  | otherwise = Right ()
