-- | Core types for the Shibuya framework.
-- These types exist everywhere and should be extremely stable.
-- No behavior, no effects, no policy - just identity + payload + metadata.
module Shibuya.Core.Types
  ( -- * Message Identity
    MessageId (..),

    -- * Cursor / Offset
    Cursor (..),

    -- * Delivery Attempt
    Attempt (..),

    -- * Message Envelope
    Envelope (..),

    -- * Message Headers
    Headers,

    -- * Trace Context
    TraceHeaders,
  )
where

import Control.DeepSeq (NFData (..))
import Data.ByteString (ByteString)
import Data.HashMap.Strict (HashMap)
import Data.String (IsString)
import OpenTelemetry.Attributes (Attribute (..))
import Shibuya.Prelude

-- | Stable identity for idempotency & observability.
-- Every message has a unique identifier.
newtype MessageId = MessageId {unMessageId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString)
  deriving anyclass (NFData)

-- | Optional cursor / offset / global position.
-- Used to track position in ordered streams.
data Cursor
  = CursorInt !Int
  | CursorText !Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (NFData)

-- | Zero-indexed delivery attempt count.
-- 0 means first delivery; 1 means first retry; and so on.
-- Adapters that cannot track redeliveries report 'Nothing' on the envelope.
newtype Attempt = Attempt {unAttempt :: Word}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (Num, Real, Enum, Integral, Bounded)
  deriving anyclass (NFData)

-- | Raw message headers as delivered by the source broker.
--
-- An ordered list of @(key, value)@ byte-string pairs. Order is
-- preserved and duplicate keys are allowed, because brokers such as
-- Kafka permit multiple headers with the same key and define header
-- order. Keys and values are raw 'ByteString' because header values
-- are not guaranteed to be UTF-8 text (for example a binary schema
-- id); decoding is left to the handler.
type Headers = [(ByteString, ByteString)]

-- | W3C Trace Context headers for distributed tracing.
-- Contains traceparent and optionally tracestate headers.
type TraceHeaders = [(ByteString, ByteString)]

-- | Normalized message envelope (Broadway.Message equivalent).
-- Contains message metadata plus the payload.
data Envelope msg = Envelope
  { -- | Unique message identifier
    messageId :: !MessageId,
    -- | Optional position/offset
    cursor :: !(Maybe Cursor),
    -- | Optional partition key (for Kafka-style queues)
    partition :: !(Maybe Text),
    -- | When the message was enqueued
    enqueuedAt :: !(Maybe UTCTime),
    -- | W3C trace context headers for distributed tracing
    traceContext :: !(Maybe TraceHeaders),
    -- | All message headers as delivered by the source broker, in
    -- order and including duplicates.
    --
    -- 'Nothing' means the adapter does not surface headers at all;
    -- 'Just []' means the adapter surfaces headers and this message
    -- carried none. The W3C trace headers ('traceparent' /
    -- 'tracestate') appear here verbatim /in addition to/ their
    -- parsed form in 'traceContext'; this field is the faithful,
    -- non-lossy view and 'traceContext' is the narrow projection the
    -- framework uses to re-establish a parent span.
    headers :: !(Maybe Headers),
    -- | Optional zero-indexed delivery counter.
    -- 'Just (Attempt 0)' on first delivery; 'Nothing' if the adapter
    -- does not track redeliveries (e.g., Kafka).
    attempt :: !(Maybe Attempt),
    -- | Adapter-supplied OpenTelemetry attributes for the per-message
    -- processing span.
    --
    -- The framework's @processOne@ adds these to its Consumer-kind
    -- span after setting the spec-aligned @messaging.*@ defaults, so
    -- adapter-supplied keys override framework defaults of the same
    -- name. Use 'Data.HashMap.Strict.empty' when the adapter has
    -- nothing to contribute (the common case).
    --
    -- Adapters that emit broker-specific typed attributes
    -- (e.g. Kafka's @messaging.kafka.destination.partition@) should
    -- populate this field at envelope-construction time. The
    -- previous opt-in @Shibuya.Adapter.Kafka.Tracing.traced@
    -- transformer existed only to bolt these on; this field replaces
    -- that mechanism without the duplicate-span hazard.
    attributes :: !(HashMap Text Attribute),
    -- | The actual message payload
    payload :: !msg
  }
  deriving stock (Eq, Show, Functor, Generic)

-- | Manual 'NFData' so the @attributes@ field's 'Attribute' values do
-- not require an upstream NFData instance (which
-- @hs-opentelemetry-api@ does not currently ship). Forces every other
-- field deeply and reduces 'attributes' to WHNF — every 'Attribute'
-- leaf is a small primitive ('Text', 'Bool', 'Double', 'Int64'), so
-- WHNF is enough to evaluate the contained values when the HashMap
-- is itself in WHNF.
instance (NFData msg) => NFData (Envelope msg) where
  rnf e =
    rnf e.messageId `seq`
      rnf e.cursor `seq`
        rnf e.partition `seq`
          rnf e.enqueuedAt `seq`
            rnf e.traceContext `seq`
              rnf e.headers `seq`
                rnf e.attempt `seq`
                  e.attributes `seq`
                    rnf e.payload
