-- | W3C Trace Context propagation for Shibuya.
-- Extracts and injects trace context from/to message headers.
module Shibuya.Telemetry.Propagation
  ( -- * Extraction
    extractTraceContext,

    -- * Injection
    injectTraceContext,

    -- * Re-export
    TraceHeaders,
  )
where

import OpenTelemetry.Propagator.W3CTraceContext qualified as W3C
import OpenTelemetry.Trace.Core (Span, SpanContext)
import Shibuya.Core.Types (TraceHeaders)

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
