-- | Semantic conventions for Shibuya OpenTelemetry instrumentation.
-- Provides span names, attribute keys, and helpers following OTel conventions.
module Shibuya.Telemetry.Semantic
  ( -- * Span Names
    processMessageSpanName,
    ingestSpanName,

    -- * Attribute Keys (OTel Messaging Conventions)
    attrMessagingSystem,
    attrMessagingMessageId,
    attrMessagingDestinationName,
    attrMessagingDestinationPartitionId,

    -- * Attribute Keys (Shibuya-specific)
    attrShibuyaProcessorId,
    attrShibuyaInflightCount,
    attrShibuyaInflightMax,
    attrShibuyaAckDecision,

    -- * Event Names
    eventHandlerStarted,
    eventHandlerCompleted,
    eventHandlerException,
    eventAckDecision,

    -- * SpanArguments Helpers
    consumerSpanArgs,
    internalSpanArgs,

    -- * NewEvent Helper
    mkEvent,
  )
where

import Data.HashMap.Strict qualified as HashMap
import Data.Text (Text)
import OpenTelemetry.Attributes (Attribute)
import OpenTelemetry.Trace.Core
  ( NewEvent (..),
    SpanArguments (..),
    SpanKind (..),
  )

--------------------------------------------------------------------------------
-- Span Names
--------------------------------------------------------------------------------

-- | Span name for processing a single message.
processMessageSpanName :: Text
processMessageSpanName = "shibuya.process.message"

-- | Span name for the ingester lifecycle.
ingestSpanName :: Text
ingestSpanName = "shibuya.ingest"

--------------------------------------------------------------------------------
-- Attribute Keys (OTel Messaging Semantic Conventions)
-- See: https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/
--------------------------------------------------------------------------------

-- | The messaging system identifier.
attrMessagingSystem :: Text
attrMessagingSystem = "messaging.system"

-- | The message identifier.
attrMessagingMessageId :: Text
attrMessagingMessageId = "messaging.message.id"

-- | The destination (queue/topic) name.
attrMessagingDestinationName :: Text
attrMessagingDestinationName = "messaging.destination.name"

-- | The partition identifier.
attrMessagingDestinationPartitionId :: Text
attrMessagingDestinationPartitionId = "messaging.destination.partition.id"

--------------------------------------------------------------------------------
-- Attribute Keys (Shibuya-specific)
--------------------------------------------------------------------------------

-- | The processor identifier.
attrShibuyaProcessorId :: Text
attrShibuyaProcessorId = "shibuya.processor.id"

-- | Current number of in-flight messages.
attrShibuyaInflightCount :: Text
attrShibuyaInflightCount = "shibuya.inflight.count"

-- | Maximum concurrency limit.
attrShibuyaInflightMax :: Text
attrShibuyaInflightMax = "shibuya.inflight.max"

-- | The ack decision made by the handler.
attrShibuyaAckDecision :: Text
attrShibuyaAckDecision = "shibuya.ack.decision"

--------------------------------------------------------------------------------
-- Event Names
--------------------------------------------------------------------------------

-- | Event recorded when handler execution starts.
eventHandlerStarted :: Text
eventHandlerStarted = "handler.started"

-- | Event recorded when handler execution completes successfully.
eventHandlerCompleted :: Text
eventHandlerCompleted = "handler.completed"

-- | Event recorded when handler throws an exception.
eventHandlerException :: Text
eventHandlerException = "handler.exception"

-- | Event recorded when ack decision is made.
eventAckDecision :: Text
eventAckDecision = "ack.decision"

--------------------------------------------------------------------------------
-- SpanArguments Helpers
--------------------------------------------------------------------------------

-- | SpanArguments for message consumption (Consumer kind).
consumerSpanArgs :: SpanArguments
consumerSpanArgs =
  SpanArguments
    { kind = Consumer,
      attributes = HashMap.empty,
      links = [],
      startTime = Nothing
    }

-- | SpanArguments for internal operations (Internal kind).
internalSpanArgs :: SpanArguments
internalSpanArgs =
  SpanArguments
    { kind = Internal,
      attributes = HashMap.empty,
      links = [],
      startTime = Nothing
    }

--------------------------------------------------------------------------------
-- NewEvent Helper
--------------------------------------------------------------------------------

-- | Create a NewEvent with the given name and attributes.
-- Use 'toAttribute' to convert values to Attribute.
--
-- Example:
--
-- @
-- mkEvent "handler.completed"
--   [ ("duration_ms", toAttribute (42 :: Int))
--   , ("status", toAttribute ("ok" :: Text))
--   ]
-- @
mkEvent :: Text -> [(Text, Attribute)] -> NewEvent
mkEvent name attrs =
  NewEvent
    { newEventName = name,
      newEventAttributes = HashMap.fromList attrs,
      newEventTimestamp = Nothing
    }
