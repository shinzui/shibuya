-- | Semantic conventions for Shibuya OpenTelemetry instrumentation.
-- Provides span names, attribute keys, and helpers following OTel conventions.
--
-- Attribute keys for the OTel @messaging.*@ namespace are derived from the
-- typed @AttributeKey@ values exported by @OpenTelemetry.SemanticConventions@,
-- so an upstream rename surfaces as a Haskell compile error rather than a
-- silent wire-format drift.
module Shibuya.Telemetry.Semantic
  ( -- * Span Names
    processSpanName,
    ingestSpanName,

    -- * Attribute Keys (OTel Messaging Conventions)
    attrMessagingSystem,
    attrMessagingMessageId,
    attrMessagingDestinationName,
    attrMessagingOperation,

    -- * Attribute Keys (Shibuya-specific)
    attrShibuyaProcessorId,
    attrShibuyaInflightCount,
    attrShibuyaInflightMax,
    attrShibuyaAckDecision,
    attrShibuyaPartition,

    -- * Event Names
    eventHandlerStarted,
    eventHandlerCompleted,
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
import OpenTelemetry.Attributes (Attribute, AttributeKey (..))
import OpenTelemetry.SemanticConventions qualified as Sem
import OpenTelemetry.Trace.Core
  ( NewEvent (..),
    SpanArguments (..),
    SpanKind (..),
  )

--------------------------------------------------------------------------------
-- Span Names
--------------------------------------------------------------------------------

-- | Span name for processing a single message.
--
-- Follows the OpenTelemetry messaging-spans recommendation that consumer
-- spans be named @\"<destination> <operation>\"@ — for Shibuya the
-- destination is the processor id and the operation is @\"process\"@,
-- yielding e.g. @\"shibuya-consumer process\"@.
--
-- This intentionally departs from
-- @hs-opentelemetry-instrumentation-hw-kafka-client@'s
-- @\"process <topic>\"@ order in favor of the spec's order; see
-- @docs/plans/2-align-opentelemetry-semantic-conventions.md@.
processSpanName :: Text -> Text
processSpanName destination = destination <> " process"

-- | Span name for the ingester lifecycle.
ingestSpanName :: Text
ingestSpanName = "shibuya.ingest"

--------------------------------------------------------------------------------
-- Attribute Keys (OTel Messaging Semantic Conventions)
-- See: https://opentelemetry.io/docs/specs/semconv/messaging/messaging-spans/
--
-- Each constant is the wire string of a typed 'AttributeKey' exported by
-- 'OpenTelemetry.SemanticConventions'. Using @unkey@ (the AttributeKey
-- newtype selector) keeps these strings in lock-step with the upstream
-- code-generated keys.
--------------------------------------------------------------------------------

-- | The messaging system identifier (@messaging.system@).
attrMessagingSystem :: Text
attrMessagingSystem = unkey Sem.messaging_system

-- | The message identifier (@messaging.message.id@).
attrMessagingMessageId :: Text
attrMessagingMessageId = unkey Sem.messaging_message_id

-- | The destination (queue/topic) name (@messaging.destination.name@).
attrMessagingDestinationName :: Text
attrMessagingDestinationName = unkey Sem.messaging_destination_name

-- | The messaging operation (@messaging.operation@).
--
-- One of the spec-defined enum values: @publish@, @receive@, @process@,
-- @settle@, @create@. Shibuya's per-message span uses @"process"@.
attrMessagingOperation :: Text
attrMessagingOperation = unkey Sem.messaging_operation

--------------------------------------------------------------------------------
-- Attribute Keys (Shibuya-specific)
--
-- These keys are intentionally outside the upstream OTel spec. The
-- semantic-conventions guide is explicit that non-spec attributes should
-- carry a vendor prefix; @shibuya.*@ satisfies that and cannot collide
-- with any current or future spec key.
--------------------------------------------------------------------------------

-- | The processor identifier (@shibuya.processor.id@).
-- Shibuya-specific: identifies a deployment-level processor instance.
attrShibuyaProcessorId :: Text
attrShibuyaProcessorId = "shibuya.processor.id"

-- | Current number of in-flight messages (@shibuya.inflight.count@).
-- Shibuya-specific: a property of Shibuya's supervision/concurrency model.
attrShibuyaInflightCount :: Text
attrShibuyaInflightCount = "shibuya.inflight.count"

-- | Maximum concurrency limit (@shibuya.inflight.max@).
-- Shibuya-specific: a property of Shibuya's supervision/concurrency model.
attrShibuyaInflightMax :: Text
attrShibuyaInflightMax = "shibuya.inflight.max"

-- | The ack decision made by the handler (@shibuya.ack.decision@).
-- Shibuya-specific: there is no upstream key for an explicit ack decision.
attrShibuyaAckDecision :: Text
attrShibuyaAckDecision = "shibuya.ack.decision"

-- | A generic partition identifier (@shibuya.partition@).
--
-- Shibuya-specific: in semantic-conventions v1.24 there is no portable
-- @messaging.destination.partition.id@ key — only system-specific ones
-- (@messaging.kafka.destination.partition@,
-- @messaging.eventhubs.destination.partition.id@). System-specific
-- adapters that know which broker is in use may emit those in addition,
-- but a generic Shibuya envelope only carries an opaque partition string,
-- which we surface under this vendor-prefixed key.
attrShibuyaPartition :: Text
attrShibuyaPartition = "shibuya.partition"

--------------------------------------------------------------------------------
-- Event Names
--
-- Shibuya-namespaced; the upstream spec does not define handler.* events.
-- The standard @exception@ event (with @exception.type@/@exception.message@/
-- @exception.stacktrace@) is emitted by 'OpenTelemetry.Trace.Core.recordException'
-- and so is not duplicated here.
--------------------------------------------------------------------------------

-- | Event recorded when handler execution starts (@shibuya.handler.started@).
eventHandlerStarted :: Text
eventHandlerStarted = "shibuya.handler.started"

-- | Event recorded when handler execution completes successfully
-- (@shibuya.handler.completed@).
eventHandlerCompleted :: Text
eventHandlerCompleted = "shibuya.handler.completed"

-- | Event recorded when ack decision is made (@shibuya.ack.decision@).
eventAckDecision :: Text
eventAckDecision = "shibuya.ack.decision"

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
