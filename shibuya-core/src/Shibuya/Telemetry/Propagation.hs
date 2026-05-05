-- | W3C Trace Context propagation for Shibuya.
-- Extracts and injects trace context from/to message headers.
module Shibuya.Telemetry.Propagation
  ( -- * Extraction
    extractTraceContext,

    -- * Injection
    injectTraceContext,
    currentTraceHeaders,

    -- * Re-export
    TraceHeaders,
  )
where

import Effectful (Eff, IOE, liftIO, (:>))
import OpenTelemetry.Context qualified as Ctx
import OpenTelemetry.Context.ThreadLocal qualified as Ctx
import OpenTelemetry.Propagator.W3CTraceContext qualified as W3C
import OpenTelemetry.Trace.Core (Span, SpanContext)
import Shibuya.Core.Types (TraceHeaders)
import Shibuya.Telemetry.Effect (Tracing, isTracingEnabled)

-- | Extract SpanContext from W3C trace headers.
-- Returns Nothing if headers are missing or malformed.
--
-- Example:
--
-- @
-- let headers = [("traceparent", "00-abc123...-def456...-01")]
-- case extractTraceContext headers of
--   Nothing -> -- no valid trace context
--   Just ctx -> -- use ctx as parent
-- @
extractTraceContext :: TraceHeaders -> Maybe SpanContext
extractTraceContext headers =
  let traceparent = lookup "traceparent" headers
      tracestate = lookup "tracestate" headers
   in W3C.decodeSpanContext traceparent tracestate

-- | Inject current span's context into headers for propagation.
-- Use this when producing messages that should carry trace context.
--
-- Example:
--
-- @
-- headers <- injectTraceContext currentSpan
-- -- headers contains [("traceparent", "..."), ("tracestate", "...")]
-- @
injectTraceContext :: Span -> IO TraceHeaders
injectTraceContext otelSpan = do
  (traceparent, tracestate) <- W3C.encodeSpanContext otelSpan
  pure
    [ ("traceparent", traceparent),
      ("tracestate", tracestate)
    ]

-- | Look up the currently-active OTel span and encode its context as
-- W3C trace headers, ready to attach to an outgoing message.
--
-- Returns 'Nothing' when tracing is disabled or when there is no
-- active span at the call site (e.g. a producer running outside any
-- 'Shibuya.Telemetry.Effect.withSpan'/@withSpan'@ scope).
--
-- This is the higher-level helper most call sites want — adapter
-- code that forwards a message (a DLQ write from @AckDeadLetter@,
-- a producer publishing a follow-on event) can do:
--
-- @
-- consumerHeaders <- currentTraceHeaders
-- let outgoingHeaders =
--       maybe originalHeaders (\\h -> h <> originalHeaders) consumerHeaders
-- @
--
-- and the failing-consumer's trace shows up linked to the resulting
-- message in the downstream trace store. The lower-level
-- 'injectTraceContext' is still exported for callers that already
-- hold a 'Span' handle from inside a 'withSpan''.
currentTraceHeaders ::
  (Tracing :> es, IOE :> es) =>
  Eff es (Maybe TraceHeaders)
currentTraceHeaders = do
  enabled <- isTracingEnabled
  if not enabled
    then pure Nothing
    else liftIO $ do
      ctx <- Ctx.getContext
      case Ctx.lookupSpan ctx of
        Nothing -> pure Nothing
        Just sp -> Just <$> injectTraceContext sp
