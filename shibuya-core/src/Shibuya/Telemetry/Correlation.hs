-- | How a processing span relates to the span that created its message.
--
-- A message's /creation context/ is the span identity its producer encoded
-- in the W3C trace headers the adapter extracted into
-- 'Shibuya.Core.Types.Envelope'@.traceContext@. Every processing span links to
-- the creation context when one decodes, as the OpenTelemetry messaging
-- conventions recommend. Whether the span is also a /child/ of that context
-- is the adapter's declared 'TraceCorrelation' policy.
module Shibuya.Telemetry.Correlation
  ( -- * Policy
    TraceCorrelation (..),
    AdapterTelemetry (traceCorrelation),
    defaultAdapterTelemetry,

    -- * Links
    creationLink,
    creationLinkWith,
    consumerSpanArgsLinkedTo,
  )
where

import Control.DeepSeq (NFData)
import Data.HashMap.Strict qualified as HashMap
import GHC.Generics (Generic)
import OpenTelemetry.Attributes (AttributeMap)
import OpenTelemetry.Trace.Core (NewLink (..), SpanArguments (..), SpanKind (..))
import Shibuya.Core.Types (TraceHeaders)
import Shibuya.Telemetry.Propagation (extractTraceContext)

-- | How a processing span relates to the span that created the message.
--
-- Both policies link the processing span to the creation context when the
-- message's trace headers decode. Without usable headers neither policy adds
-- a link, and the span is opened in the ambient context exactly as before.
data TraceCorrelation
  = -- | Child of the creation context, and linked to it: one connected trace
    -- from producer to consumer. Suits queues consumed soon after production.
    ParentAndLink
  | -- | A new root trace, related to the creation context only by a link.
    -- Suits replayed event streams, long-delayed or retried jobs, fan-out to
    -- many consumers, and tail-sampling deployments: the consumer trace is
    -- sampled independently of the producer's.
    LinkOnly
  deriving stock (Eq, Show, Generic, Enum, Bounded)
  deriving anyclass (NFData)

-- | Telemetry options an adapter declares in its 'Shibuya.Adapter.Adapter'.
--
-- Build a value from 'defaultAdapterTelemetry' with record update:
--
-- @
-- defaultAdapterTelemetry {traceCorrelation = LinkOnly}
-- @
--
-- The constructor is not exported, so options can be added later as fields
-- with defaults without breaking any adapter. The framework reads it once per
-- processor, never per message.
data AdapterTelemetry = AdapterTelemetry
  { -- | Parent-versus-link policy for this adapter's processing spans.
    traceCorrelation :: !TraceCorrelation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | @traceCorrelation = 'ParentAndLink'@.
defaultAdapterTelemetry :: AdapterTelemetry
defaultAdapterTelemetry = AdapterTelemetry {traceCorrelation = ParentAndLink}

-- | Decode trace headers into a link to the message's creation context.
--
-- 'Nothing' when the headers are absent or malformed. The link carries no
-- attributes (the shared empty map), holds an evaluated
-- 'OpenTelemetry.Trace.Core.SpanContext', and keeps no reference to the
-- header list.
creationLink :: TraceHeaders -> Maybe NewLink
creationLink = creationLinkWith HashMap.empty
{-# INLINE creationLink #-}

-- | As 'creationLink', with attributes describing the linked message (for
-- example its @messaging.message.id@ on a batch span). The caller supplies an
-- already evaluated map.
creationLinkWith :: AttributeMap -> TraceHeaders -> Maybe NewLink
creationLinkWith attrs headers = case extractTraceContext headers of
  Nothing -> Nothing
  Just ctx ->
    let !link = NewLink {linkContext = ctx, linkAttributes = attrs}
     in Just link
{-# INLINE creationLinkWith #-}

-- | Consumer-kind span arguments carrying the given links. The list must be
-- fully evaluated by the caller, so the span references nothing else.
--
-- 'Shibuya.Telemetry.Semantic.consumerSpanArgs' remains the constant for
-- spans without links.
consumerSpanArgsLinkedTo :: [NewLink] -> SpanArguments
consumerSpanArgsLinkedTo links =
  SpanArguments
    { kind = Consumer,
      attributes = HashMap.empty,
      links = links,
      startTime = Nothing
    }
{-# INLINE consumerSpanArgsLinkedTo #-}
