-- | Internal implementation details for the PGMQ adapter.
-- This module is not part of the public API and may change without notice.
module Shibuya.Adapter.Pgmq.Internal
  ( -- * Stream Construction
    pgmqSource,

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
  )
import Pgmq.Hasql.Statements.Types
  ( MessageQuery (..),
    ReadGrouped (..),
    ReadGroupedWithPoll (..),
    ReadMessage (..),
    ReadWithPollMessage (..),
    SendMessage (..),
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
          -- Send to DLQ with metadata
          let dlqBody = mkDlqPayload msg reason dlqConfig.includeMetadata
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

-- | Create the message source stream.
-- This stream polls pgmq and yields Ingested messages.
pgmqSource ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Stream (Eff es) (Ingested es Value)
pgmqSource config =
  Stream.catMaybes $ Stream.repeatM pollAndConvert
  where
    pollAndConvert :: (Pgmq :> es, IOE :> es) => Eff es (Maybe (Ingested es Value))
    pollAndConvert = do
      msgs <- poll
      case Vector.uncons msgs of
        Nothing -> pure Nothing
        Just (msg, _rest) -> mkIngested config msg

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
