-- | The Consumer-kind processing span for one message.
--
-- Shibuya's own runner opens every per-message processing span through
-- 'withProcessSpan'. It is exported so code that drains an adapter outside
-- the runner opens the same span, with the same link and parent rule, instead
-- of a hand-written copy that can drift.
--
-- The rule, decided once per call:
--
-- 1. Tracing disabled: the body receives the shared non-recording sentinel
--    span. The trace headers are not inspected.
-- 2. Tracing enabled, no usable creation context (headers absent or
--    malformed): the span is opened in the ambient context, with no link,
--    exactly as Shibuya did before trace correlation policies existed.
-- 3. Tracing enabled, the headers decode: the span links to the creation
--    context. Under 'ParentAndLink' it is also a child of it; under
--    'LinkOnly' it is a root in a new trace. The previous thread context is
--    restored afterwards, also on exceptions and cancellation.
--
-- In case 3 neither policy preserves an enclosing ambient operation: it is
-- neither the parent nor linked. These helpers are for /independent/ message
-- processing. A caller that processes a message inside a meaningful
-- enclosing operation, and wants that relationship recorded, must open its
-- own span rather than use these helpers.
--
-- The functions set no attributes and record no outcome; both remain the
-- caller's.
module Shibuya.Telemetry.Process
  ( withProcessSpan,
    withProcessSpanIO,
  )
where

import Control.Exception (bracket)
import Data.Text (Text)
import Effectful (Eff, IOE, Limit (..), Persistence (..), UnliftStrategy (..), withEffToIO, (:>))
import OpenTelemetry.Context qualified as Ctx
import OpenTelemetry.Context.ThreadLocal qualified as Ctx
import OpenTelemetry.Trace.Core (NewLink (..), Span, SpanArguments, Tracer)
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Core.Types (TraceHeaders)
import Shibuya.Telemetry.Correlation (TraceCorrelation (..), consumerSpanArgsLinkedTo, creationLink)
import Shibuya.Telemetry.Effect (Tracing, getTracer, isTracingEnabled, withSpan')
import Shibuya.Telemetry.Semantic (consumerSpanArgs)

-- | Open the Consumer-kind processing span for one message.
--
-- Linked to the creation context in the headers when one decodes; a child of
-- it under 'ParentAndLink'; a root under 'LinkOnly'. Without usable headers
-- the span is opened in the ambient context, as before. With tracing
-- disabled the body receives the sentinel span and no header is decoded.
-- With valid headers a meaningful ambient operation is neither parented nor
-- linked: callers opt into independent message processing by using this
-- helper (see the module documentation).
withProcessSpan ::
  (Tracing :> es, IOE :> es) =>
  TraceCorrelation ->
  -- | Full span name, e.g. @processSpanName destination@.
  Text ->
  -- | The message's trace headers ('Shibuya.Core.Types.Envelope'@.traceContext@).
  Maybe TraceHeaders ->
  (Span -> Eff es a) ->
  Eff es a
withProcessSpan policy name headers body = do
  enabled <- isTracingEnabled
  if not enabled
    then withSpan' name consumerSpanArgs body
    else case processSpanPlan policy headers of
      Nothing -> withSpan' name consumerSpanArgs body
      Just (context, args) -> do
        tracer <- getTracer
        -- One unlift covers both the context attachment and the span.
        withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
          inContext context $ OTel.inSpan' tracer name args (runInIO . body)
{-# INLINE withProcessSpan #-}

-- | The same span for callers that hold a 'Tracer' outside the 'Tracing'
-- effect. It always behaves as tracing enabled; pass a tracer from a no-op
-- provider to disable it.
withProcessSpanIO ::
  Tracer ->
  TraceCorrelation ->
  -- | Full span name, e.g. @processSpanName destination@.
  Text ->
  Maybe TraceHeaders ->
  (Span -> IO a) ->
  IO a
withProcessSpanIO tracer policy name headers body =
  case processSpanPlan policy headers of
    Nothing -> OTel.inSpan' tracer name consumerSpanArgs body
    Just (context, args) -> inContext context $ OTel.inSpan' tracer name args body
{-# INLINE withProcessSpanIO #-}

-- | The decision shared by both entry points. 'Nothing': open the span in
-- the ambient context without links. @Just (context, args)@: attach
-- @context@ (the creation context for 'ParentAndLink', the empty context for
-- 'LinkOnly') and open the span with @args@, which carry the one link.
--
-- The headers are decoded once; the link, its one-element list and the
-- arguments are evaluated before the span exists, so the span references
-- neither the headers nor anything else of the message.
processSpanPlan :: TraceCorrelation -> Maybe TraceHeaders -> Maybe (Ctx.Context, SpanArguments)
processSpanPlan policy headers = case headers of
  Nothing -> Nothing
  Just hs -> case creationLink hs of
    Nothing -> Nothing
    Just link ->
      let !args = consumerSpanArgsLinkedTo [link]
          !context = case policy of
            ParentAndLink -> Ctx.insertSpan (OTel.wrapSpanContext link.linkContext) Ctx.empty
            LinkOnly -> Ctx.empty
       in Just (context, args)
{-# INLINE processSpanPlan #-}

-- | Attach a context for the duration of an action, restoring the previous
-- one on normal exit, exception and asynchronous cancellation.
inContext :: Ctx.Context -> IO a -> IO a
inContext context action =
  bracket (Ctx.attachContext context) Ctx.detachContext (const action)
{-# INLINE inContext #-}
