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

    -- * Batch links
    maxBatchLinks,
    BatchLinks (..),
    collectBatchLinks,
    collectBatchLinksBy,
  )
where

import Control.DeepSeq (NFData)
import Data.HashMap.Strict qualified as HashMap
import GHC.Generics (Generic)
import OpenTelemetry.Attributes (AttributeMap, toAttribute)
import OpenTelemetry.Trace.Core (NewLink (..), SpanArguments (..), SpanContext, SpanKind (..))
import Shibuya.Core.Types (MessageId (..), TraceHeaders)
import Shibuya.Telemetry.Propagation (extractTraceContext)
import Shibuya.Telemetry.Semantic (attrMessagingMessageId)

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

-- | Maximum links Shibuya places on one batch span: the OpenTelemetry SDK's
-- default per-span link limit. A lower configured SDK limit
-- (@OTEL_SPAN_LINK_COUNT_LIMIT@) can still drop supplied links on its own.
maxBatchLinks :: Int
maxBatchLinks = 128

-- | The creation-context links collected for one batch.
data BatchLinks = BatchLinks
  { -- | One link per member with a decodable creation context, in member
    -- order, each carrying that member's @messaging.message.id@. Fully
    -- evaluated; at most 'maxBatchLinks' long.
    links :: ![NewLink],
    -- | Members with a decodable creation context beyond 'maxBatchLinks'.
    -- Absent and malformed contexts are never counted.
    dropped :: !Int
  }

-- | 'collectBatchLinksBy' over @(message id, trace headers)@ pairs.
collectBatchLinks :: [(MessageId, Maybe TraceHeaders)] -> BatchLinks
collectBatchLinks = collectBatchLinksBy fst snd
{-# INLINE collectBatchLinks #-}

-- | Collect one link per member that has a decodable creation context, in
-- order, each carrying @messaging.message.id@. At most 'maxBatchLinks' links
-- are stored. Decoding continues past the bound so that 'dropped' counts the
-- valid omitted contexts exactly, but no link or attribute map is built for
-- them.
--
-- One strict pass with strict accumulators. A member whose raw headers equal
-- the previous member's reuses that member's decoded context. Members that
-- share a context still get separate links, because the links carry
-- different message identifiers. The result references only evaluated span
-- contexts and identifier text, never the members.
collectBatchLinksBy :: (Foldable t) => (a -> MessageId) -> (a -> Maybe TraceHeaders) -> t a -> BatchLinks
collectBatchLinksBy messageIdOf headersOf members =
  case foldl' step (Acc 0 [] 0 Nothing Nothing) members of
    Acc _ collected omitted _ _ -> BatchLinks {links = reverse collected, dropped = omitted}
  where
    step acc@(Acc count collected omitted previousHeaders previousContext) member =
      case headersOf member of
        Nothing -> acc
        Just headers ->
          let !context =
                if Just headers == previousHeaders
                  then previousContext
                  else extractTraceContext headers
           in case context of
                Nothing -> Acc count collected omitted (Just headers) context
                Just spanContext
                  | count < maxBatchLinks ->
                      let MessageId idText = messageIdOf member
                          !attrs = HashMap.singleton attrMessagingMessageId $! toAttribute idText
                          !link = NewLink {linkContext = spanContext, linkAttributes = attrs}
                       in Acc (count + 1) (link : collected) omitted (Just headers) context
                  | otherwise -> Acc count collected (omitted + 1) (Just headers) context
{-# INLINE collectBatchLinksBy #-}

-- Strict fold state: links so far, reversed, with their count; the overflow
-- count; and the previous member's raw headers and decoded context.
data Acc = Acc !Int ![NewLink] !Int !(Maybe TraceHeaders) !(Maybe SpanContext)
