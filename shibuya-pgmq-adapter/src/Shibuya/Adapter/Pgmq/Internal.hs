-- | Internal implementation details for the PGMQ adapter.
-- This module is not part of the public API and may change without notice.
module Shibuya.Adapter.Pgmq.Internal
  ( -- * Stream Construction
    pgmqSource,
    pgmqSourceWithPrefetch,
    pgmqChunks,
    pgmqChunksPrefetch,
    pgmqMessages,
    pgmqMessagesPrefetch,

    -- * Ingested Construction
    mkIngested,

    -- * AckHandle Construction
    mkAckHandle,

    -- * Lease Construction
    mkLease,

    -- * Query Construction
    mkReadMessage,
    mkReadWithPoll,
    mkReadGrouped,
    mkReadGroupedWithPoll,

    -- * Utilities
    nominalToSeconds,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Data.Function ((&))
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, nominalDiffTimeToSeconds)
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, (:>))
import Pgmq.Effectful.Effect
  ( Pgmq,
    archiveMessage,
    changeVisibilityTimeout,
    deleteMessage,
    readGrouped,
    readGroupedRoundRobin,
    readGroupedRoundRobinWithPoll,
    readGroupedWithPoll,
    readMessage,
    readWithPoll,
    sendMessage,
    sendMessageWithHeaders,
  )
import Pgmq.Hasql.Statements.Types
  ( MessageQuery (..),
    ReadGrouped (..),
    ReadGroupedWithPoll (..),
    ReadMessage (..),
    ReadWithPollMessage (..),
    SendMessage (..),
    SendMessageWithHeaders (..),
    VisibilityTimeoutQuery (..),
  )
import Pgmq.Types qualified as Pgmq
import Shibuya.Adapter.Pgmq.Config
  ( DeadLetterConfig (..),
    FifoConfig (..),
    FifoReadStrategy (..),
    PgmqAdapterConfig (..),
    PollingConfig (..),
  )
import Shibuya.Adapter.Pgmq.Convert
  ( mkDlqPayload,
    pgmqMessageToEnvelope,
  )
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Lease (Lease (..))
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Stream.Prelude qualified as StreamP
import Streamly.Data.Unfold qualified as Unfold

-- | Convert NominalDiffTime to seconds as Int32 for pgmq.
nominalToSeconds :: NominalDiffTime -> Int32
nominalToSeconds = ceiling . nominalDiffTimeToSeconds

-- | Create a ReadMessage query from config.
mkReadMessage :: PgmqAdapterConfig -> ReadMessage
mkReadMessage config =
  ReadMessage
    { queueName = config.queueName,
      delay = config.visibilityTimeout,
      batchSize = Just config.batchSize,
      conditional = Nothing
    }

-- | Create a ReadWithPollMessage query from config.
mkReadWithPoll :: PgmqAdapterConfig -> Int32 -> Int32 -> ReadWithPollMessage
mkReadWithPoll config maxSec intervalMs =
  ReadWithPollMessage
    { queueName = config.queueName,
      delay = config.visibilityTimeout,
      batchSize = Just config.batchSize,
      maxPollSeconds = maxSec,
      pollIntervalMs = intervalMs,
      conditional = Nothing
    }

-- | Create a ReadGrouped query from config.
mkReadGrouped :: PgmqAdapterConfig -> ReadGrouped
mkReadGrouped config =
  ReadGrouped
    { queueName = config.queueName,
      visibilityTimeout = config.visibilityTimeout,
      qty = config.batchSize
    }

-- | Create a ReadGroupedWithPoll query from config.
mkReadGroupedWithPoll :: PgmqAdapterConfig -> Int32 -> Int32 -> ReadGroupedWithPoll
mkReadGroupedWithPoll config maxSec intervalMs =
  ReadGroupedWithPoll
    { queueName = config.queueName,
      visibilityTimeout = config.visibilityTimeout,
      qty = config.batchSize,
      maxPollSeconds = maxSec,
      pollIntervalMs = intervalMs
    }

-- | Create a Lease for visibility timeout extension.
mkLease ::
  (Pgmq :> es) =>
  Pgmq.QueueName ->
  Pgmq.MessageId ->
  Lease es
mkLease queueName msgId =
  Lease
    { leaseId = Text.pack (show (Pgmq.unMessageId msgId)),
      leaseExtend = \duration -> do
        let vtSeconds = nominalToSeconds duration
        _ <-
          changeVisibilityTimeout $
            VisibilityTimeoutQuery
              { queueName = queueName,
                messageId = msgId,
                visibilityTimeoutOffset = vtSeconds
              }
        pure ()
    }

-- | Create an AckHandle for a message.
mkAckHandle ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Pgmq.Message ->
  AckHandle es
mkAckHandle config msg = AckHandle $ \decision -> do
  let queueName = config.queueName
      msgId = msg.messageId

  case decision of
    AckOk ->
      -- Successfully processed - delete from queue
      void $ deleteMessage (MessageQuery queueName msgId)
    AckRetry (RetryDelay delay) -> do
      -- Retry after delay - extend visibility timeout
      let vtSeconds = nominalToSeconds delay
      void $
        changeVisibilityTimeout $
          VisibilityTimeoutQuery
            { queueName = queueName,
              messageId = msgId,
              visibilityTimeoutOffset = vtSeconds
            }
    AckDeadLetter reason -> do
      -- Handle dead-lettering
      case config.deadLetterConfig of
        Nothing ->
          -- No DLQ configured - just archive the message
          void $ archiveMessage (MessageQuery queueName msgId)
        Just dlqConfig -> do
          -- Send to DLQ with metadata, preserving trace context if present
          let dlqBody = mkDlqPayload msg reason dlqConfig.includeMetadata
          -- Preserve original headers (including trace context) in DLQ message
          case msg.headers of
            Just headers -> do
              -- Send with preserved headers for trace continuity
              void $
                sendMessageWithHeaders $
                  SendMessageWithHeaders
                    { queueName = dlqConfig.dlqQueueName,
                      messageBody = dlqBody,
                      messageHeaders = Pgmq.MessageHeaders headers,
                      delay = Nothing
                    }
            Nothing ->
              -- No headers to preserve, use simple send
              void $
                sendMessage $
                  SendMessage
                    { queueName = dlqConfig.dlqQueueName,
                      messageBody = dlqBody,
                      delay = Nothing
                    }
          -- Delete from original queue
          void $ deleteMessage (MessageQuery queueName msgId)
    AckHalt _reason -> do
      -- Halt processing - extend VT far into future
      -- Message becomes visible again after processor restarts
      let vtSeconds = 3600 :: Int32 -- 1 hour
      void $
        changeVisibilityTimeout $
          VisibilityTimeoutQuery
            { queueName = queueName,
              messageId = msgId,
              visibilityTimeoutOffset = vtSeconds
            }
  where
    void :: (Functor f) => f a -> f ()
    void = fmap (const ())

-- | Create an Ingested from a pgmq Message.
-- Handles auto dead-lettering when maxRetries is exceeded.
mkIngested ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Pgmq.Message ->
  Eff es (Maybe (Ingested es Value))
mkIngested config msg = do
  -- Check if max retries exceeded
  if msg.readCount > config.maxRetries
    then do
      -- Auto dead-letter messages that exceed retry limit
      let ackHandle = mkAckHandle config msg
      ackHandle.finalize (AckDeadLetter MaxRetriesExceeded)
      -- Return Nothing - this message won't be processed by handler
      pure Nothing
    else
      pure $
        Just
          Ingested
            { envelope = pgmqMessageToEnvelope msg,
              ack = mkAckHandle config msg,
              lease = Just (mkLease config.queueName msg.messageId)
            }

-- | Stream of message batches from pgmq.
-- Each element is a Vector of messages from a single poll.
-- This is the lowest-level stream that handles polling logic.
pgmqChunks ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunks config = Stream.repeatM poll
  where
    poll :: (Pgmq :> es, IOE :> es) => Eff es (Vector Pgmq.Message)
    poll = case config.fifoConfig of
      Nothing -> pollNonFifo
      Just fifo -> pollFifo fifo

    pollNonFifo :: (Pgmq :> es, IOE :> es) => Eff es (Vector Pgmq.Message)
    pollNonFifo = case config.polling of
      StandardPolling interval -> do
        result <- readMessage (mkReadMessage config)
        when (Vector.null result) $
          liftIO $
            threadDelay (nominalToMicros interval)
        pure result
      LongPolling maxSec intervalMs ->
        readWithPoll (mkReadWithPoll config maxSec intervalMs)

    pollFifo :: (Pgmq :> es, IOE :> es) => FifoConfig -> Eff es (Vector Pgmq.Message)
    pollFifo fifo = case config.polling of
      StandardPolling interval -> do
        result <- case fifo.readStrategy of
          ThroughputOptimized -> readGrouped (mkReadGrouped config)
          RoundRobin -> readGroupedRoundRobin (mkReadGrouped config)
        when (Vector.null result) $
          liftIO $
            threadDelay (nominalToMicros interval)
        pure result
      LongPolling maxSec intervalMs ->
        case fifo.readStrategy of
          ThroughputOptimized ->
            readGroupedWithPoll (mkReadGroupedWithPoll config maxSec intervalMs)
          RoundRobin ->
            readGroupedRoundRobinWithPoll (mkReadGroupedWithPoll config maxSec intervalMs)

    nominalToMicros :: NominalDiffTime -> Int
    nominalToMicros t = floor (nominalDiffTimeToSeconds t * 1_000_000)

-- | Flatten message chunks into individual messages.
-- Uses Streamly's unfoldEach to expand each Vector into individual elements,
-- ensuring ALL messages from each batch are processed (not just the first).
pgmqMessages ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) Pgmq.Message
pgmqMessages config =
  pgmqChunks config
    & Stream.filter (not . Vector.null) -- Skip empty batches
    & Stream.unfoldEach vectorUnfold -- Flatten Vector to individual elements
  where
    -- Unfold a Vector into a stream of elements using uncons
    vectorUnfold = Unfold.unfoldr Vector.uncons

-- | Create the message source stream.
-- This stream polls pgmq and yields Ingested messages.
-- Uses unfoldEach to process ALL messages from each batch, not just the first.
pgmqSource ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Ingested es Value)
pgmqSource config =
  pgmqMessages config
    & Stream.mapMaybeM (mkIngested config) -- Convert + filter auto-DLQ'd messages

-- | Stream of message batches with concurrent prefetching.
-- Uses parBuffered to poll the next batch while current batch is being processed.
-- This reduces latency by overlapping polling with message processing.
--
-- Note: Prefetched messages have their visibility timeout ticking. Ensure
-- bufferSize * batchSize * avgProcessingTime < visibilityTimeout to avoid
-- messages re-appearing before they're processed.
pgmqChunksPrefetch ::
  (Pgmq :> es, IOE :> es) =>
  (StreamP.Config -> StreamP.Config) ->
  PgmqAdapterConfig ->
  Stream (Eff es) (Vector Pgmq.Message)
pgmqChunksPrefetch prefetchConfig config =
  pgmqChunks config
    & StreamP.parBuffered prefetchConfig

-- | Flatten prefetched message chunks into individual messages.
-- Like pgmqMessages but with concurrent prefetching of batches.
pgmqMessagesPrefetch ::
  (Pgmq :> es, IOE :> es) =>
  (StreamP.Config -> StreamP.Config) ->
  PgmqAdapterConfig ->
  Stream (Eff es) Pgmq.Message
pgmqMessagesPrefetch prefetchConfig config =
  pgmqChunksPrefetch prefetchConfig config
    & Stream.filter (not . Vector.null) -- Skip empty batches
    & Stream.unfoldEach vectorUnfold -- Flatten Vector to individual elements
  where
    vectorUnfold = Unfold.unfoldr Vector.uncons

-- | Create message source stream with concurrent prefetching.
-- Polls the next batch while current messages are being processed.
--
-- This provides lower latency than pgmqSource by keeping messages ready
-- in a buffer for immediate consumption. The trade-off is that prefetched
-- messages have their visibility timeout ticking.
--
-- Usage:
--
-- @
-- -- With default prefetch settings (4 batches ahead)
-- source = pgmqSourceWithPrefetch defaultPrefetchConfig config
--
-- -- With custom buffer size
-- source = pgmqSourceWithPrefetch (StreamP.maxBuffer 2) config
-- @
pgmqSourceWithPrefetch ::
  (Pgmq :> es, IOE :> es) =>
  (StreamP.Config -> StreamP.Config) ->
  PgmqAdapterConfig ->
  Stream (Eff es) (Ingested es Value)
pgmqSourceWithPrefetch prefetchConfig config =
  pgmqMessagesPrefetch prefetchConfig config
    & Stream.mapMaybeM (mkIngested config)
