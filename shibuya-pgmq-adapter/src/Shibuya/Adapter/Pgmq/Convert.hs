-- | Type conversions between pgmq and Shibuya types.
module Shibuya.Adapter.Pgmq.Convert
  ( -- * Message Conversion
    pgmqMessageToEnvelope,
    messageIdToShibuya,
    messageIdToPgmq,

    -- * Cursor Conversion
    pgmqMessageIdToCursor,

    -- * Trace Context
    extractTraceHeaders,

    -- * DLQ Payload
    mkDlqPayload,
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Pgmq.Types qualified as Pgmq
import Shibuya.Core.Ack (DeadLetterReason (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), TraceHeaders)

-- | Convert a pgmq MessageId to a Shibuya MessageId.
-- pgmq uses Int64, Shibuya uses Text.
messageIdToShibuya :: Pgmq.MessageId -> MessageId
messageIdToShibuya (Pgmq.MessageId i) = MessageId (Text.pack (show i))

-- | Convert a Shibuya MessageId back to pgmq MessageId.
-- Returns Nothing if the text cannot be parsed as Int64.
messageIdToPgmq :: MessageId -> Maybe Pgmq.MessageId
messageIdToPgmq (MessageId t) = Pgmq.MessageId <$> readMaybe (Text.unpack t)
  where
    readMaybe :: String -> Maybe Int64
    readMaybe s = case reads s of
      [(x, "")] -> Just x
      _ -> Nothing

-- | Convert a pgmq MessageId to a Shibuya Cursor.
-- Uses CursorInt since pgmq message IDs are sequential integers.
pgmqMessageIdToCursor :: Pgmq.MessageId -> Cursor
pgmqMessageIdToCursor (Pgmq.MessageId i) = CursorInt (fromIntegral i)

-- | Extract FIFO partition from pgmq message headers.
-- Looks for the "x-pgmq-group" header key.
extractPartition :: Maybe Value -> Maybe Text
extractPartition headers = do
  Object obj <- headers
  value <- KeyMap.lookup (Key.fromText "x-pgmq-group") obj
  case value of
    String group -> Just group
    _ -> Nothing

-- | Extract W3C trace headers from pgmq message headers.
-- Looks for traceparent and tracestate header keys.
-- Returns Nothing if traceparent is not present (it's required for valid context).
extractTraceHeaders :: Maybe Value -> Maybe TraceHeaders
extractTraceHeaders Nothing = Nothing
extractTraceHeaders (Just (Object obj)) = do
  -- traceparent is required
  traceparentValue <- KeyMap.lookup (Key.fromText "traceparent") obj
  traceparent <- asText traceparentValue
  -- tracestate is optional
  let tracestate = KeyMap.lookup (Key.fromText "tracestate") obj >>= asText
  pure $
    ("traceparent", TE.encodeUtf8 traceparent)
      : maybe [] (\ts -> [("tracestate", TE.encodeUtf8 ts)]) tracestate
  where
    asText :: Value -> Maybe Text
    asText (String t) = Just t
    asText _ = Nothing
extractTraceHeaders _ = Nothing

-- | Convert a pgmq Message to a Shibuya Envelope.
-- The payload is the raw JSON Value from pgmq.
-- Extracts W3C trace context from headers if present.
pgmqMessageToEnvelope :: Pgmq.Message -> Envelope Value
pgmqMessageToEnvelope msg =
  Envelope
    { messageId = messageIdToShibuya msg.messageId,
      cursor = Just (pgmqMessageIdToCursor msg.messageId),
      partition = extractPartition msg.headers,
      enqueuedAt = Just msg.enqueuedAt,
      traceContext = extractTraceHeaders msg.headers,
      payload = Pgmq.unMessageBody msg.body
    }

-- | Create a dead-letter queue payload with optional metadata.
mkDlqPayload ::
  -- | Original message
  Pgmq.Message ->
  -- | Reason for dead-lettering
  DeadLetterReason ->
  -- | Include full metadata
  Bool ->
  -- | DLQ message body
  Pgmq.MessageBody
mkDlqPayload msg reason includeMetadata =
  Pgmq.MessageBody $
    object $
      [ "original_message" .= Pgmq.unMessageBody msg.body,
        "dead_letter_reason" .= reasonToText reason
      ]
        ++ metadataFields
  where
    metadataFields
      | includeMetadata =
          [ "original_message_id" .= Pgmq.unMessageId msg.messageId,
            "original_enqueued_at" .= msg.enqueuedAt,
            "last_read_at" .= msg.lastReadAt,
            "read_count" .= msg.readCount,
            "original_headers" .= msg.headers
          ]
      | otherwise = []

    reasonToText :: DeadLetterReason -> Text
    reasonToText = \case
      PoisonPill t -> "poison_pill: " <> t
      InvalidPayload t -> "invalid_payload: " <> t
      MaxRetriesExceeded -> "max_retries_exceeded"
