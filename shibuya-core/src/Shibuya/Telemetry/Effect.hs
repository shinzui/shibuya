{-# LANGUAGE TypeFamilies #-}

-- | Tracing effect for OpenTelemetry integration.
-- Provides a simple, low-overhead tracing API that wraps hs-opentelemetry.
module Shibuya.Telemetry.Effect
  ( -- * Effect
    Tracing,

    -- * Runners
    runTracing,
    runTracingNoop,

    -- * Span Operations
    withSpan,
    withSpan',

    -- * Span Modification
    addAttribute,
    addAttributes,
    addEvent,
    recordException,
    setStatus,

    -- * Context
    getTracer,
    isTracingEnabled,
    withExtractedContext,

    -- * Re-exports
    OTel.Span,
    OTel.SpanArguments (..),
    OTel.SpanKind (..),
    OTel.SpanStatus (..),
    OTel.NewEvent (..),
    OTel.Tracer,
    OTel.defaultSpanArguments,
    OTel.toAttribute,
  )
where

import Control.Exception (Exception, bracket_)
import Data.ByteString qualified as BS
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Text (Text)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, IOE, liftIO, withEffToIO, (:>))
import Effectful.Dispatch.Static
  ( SideEffects (..),
    StaticRep,
    evalStaticRep,
    getStaticRep,
  )
import Effectful.Internal.Unlift (Limit (..), Persistence (..), UnliftStrategy (..))
import OpenTelemetry.Attributes (Attribute, ToAttribute)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Context qualified as Ctx
import OpenTelemetry.Context.ThreadLocal qualified as Ctx
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id qualified as OTel.Id
import OpenTelemetry.Trace.TraceState qualified as OTel.TraceState

--------------------------------------------------------------------------------
-- Effect Definition
--------------------------------------------------------------------------------

-- | Tracing effect for OpenTelemetry spans.
data Tracing :: Effect

type instance DispatchOf Tracing = 'Static 'WithSideEffects

-- | Internal representation carrying the Tracer and enabled flag.
data instance StaticRep Tracing = TracingRep
  { tracer :: !OTel.Tracer,
    tracingEnabled :: !Bool
  }

--------------------------------------------------------------------------------
-- Runners
--------------------------------------------------------------------------------

-- | Run with actual tracing enabled.
-- The Tracer should be obtained from a TracerProvider.
--
-- Example:
--
-- @
-- provider <- OTel.initializeTracerProvider
-- let tracer = OTel.makeTracer provider "shibuya" OTel.tracerOptions
-- runTracing tracer myAction
-- @
runTracing ::
  (IOE :> es) =>
  OTel.Tracer ->
  Eff (Tracing : es) a ->
  Eff es a
runTracing t = evalStaticRep (TracingRep t True)

-- | Run with tracing disabled (zero overhead).
-- All tracing operations become no-ops.
runTracingNoop ::
  (IOE :> es) =>
  Eff (Tracing : es) a ->
  Eff es a
runTracingNoop action = do
  -- Create a minimal no-op tracer
  noopProvider <- liftIO $ OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
  let noopTracer = OTel.makeTracer noopProvider instrumentationLib OTel.tracerOptions
  evalStaticRep (TracingRep noopTracer False) action
  where
    instrumentationLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = "shibuya-noop",
          OTel.libraryVersion = "",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }

--------------------------------------------------------------------------------
-- Span Operations
--------------------------------------------------------------------------------

-- | Create a span wrapping an action.
-- The span is automatically ended when the action completes.
--
-- Example:
--
-- @
-- withSpan "process.message" consumerSpanArgs $ do
--   -- your code here
-- @
withSpan ::
  (Tracing :> es, IOE :> es) =>
  Text ->
  OTel.SpanArguments ->
  Eff es a ->
  Eff es a
withSpan name args action = do
  TracingRep {tracer, tracingEnabled} <- getStaticRep
  if not tracingEnabled
    then action
    else withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
      OTel.inSpan tracer name args (runInIO action)

-- | Create a span with access to the Span handle.
-- Use this when you need to add attributes or events to the span.
--
-- Example:
--
-- @
-- withSpan' "process.message" consumerSpanArgs $ \span -> do
--   addAttribute span "message.id" msgId
--   -- your code here
-- @
withSpan' ::
  (Tracing :> es, IOE :> es) =>
  Text ->
  OTel.SpanArguments ->
  (OTel.Span -> Eff es a) ->
  Eff es a
withSpan' name args f = do
  TracingRep {tracer, tracingEnabled} <- getStaticRep
  if not tracingEnabled
    then do
      -- Create a dropped span for the callback
      dummySpan <- liftIO mkDummySpan
      f dummySpan
    else withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
      OTel.inSpan' tracer name args $ \traceSpan ->
        runInIO (f traceSpan)

--------------------------------------------------------------------------------
-- Span Modification
--------------------------------------------------------------------------------

-- | Add an attribute to a span.
addAttribute ::
  (Tracing :> es, IOE :> es, ToAttribute a) =>
  OTel.Span ->
  Text ->
  a ->
  Eff es ()
addAttribute traceSpan key val = do
  TracingRep {tracingEnabled} <- getStaticRep
  if not tracingEnabled
    then pure ()
    else liftIO $ OTel.addAttribute traceSpan key val

-- | Add multiple attributes to a span.
addAttributes ::
  (Tracing :> es, IOE :> es) =>
  OTel.Span ->
  HashMap Text Attribute ->
  Eff es ()
addAttributes traceSpan attrs = do
  TracingRep {tracingEnabled} <- getStaticRep
  if not tracingEnabled
    then pure ()
    else liftIO $ OTel.addAttributes traceSpan attrs

-- | Add an event to a span.
addEvent ::
  (Tracing :> es, IOE :> es) =>
  OTel.Span ->
  OTel.NewEvent ->
  Eff es ()
addEvent traceSpan event = do
  TracingRep {tracingEnabled} <- getStaticRep
  if not tracingEnabled
    then pure ()
    else liftIO $ OTel.addEvent traceSpan event

-- | Record an exception on a span.
-- This adds an "exception" event with stack trace information.
recordException ::
  (Tracing :> es, IOE :> es, Exception e) =>
  OTel.Span ->
  e ->
  Eff es ()
recordException traceSpan ex = do
  TracingRep {tracingEnabled} <- getStaticRep
  if not tracingEnabled
    then pure ()
    else liftIO $ OTel.recordException traceSpan HashMap.empty Nothing ex

-- | Set the status of a span.
setStatus ::
  (Tracing :> es, IOE :> es) =>
  OTel.Span ->
  OTel.SpanStatus ->
  Eff es ()
setStatus traceSpan status = do
  TracingRep {tracingEnabled} <- getStaticRep
  if not tracingEnabled
    then pure ()
    else liftIO $ OTel.setStatus traceSpan status

--------------------------------------------------------------------------------
-- Context Operations
--------------------------------------------------------------------------------

-- | Get the current tracer.
getTracer ::
  (Tracing :> es) =>
  Eff es OTel.Tracer
getTracer = do
  TracingRep {tracer} <- getStaticRep
  pure tracer

-- | Check if tracing is enabled.
isTracingEnabled ::
  (Tracing :> es) =>
  Eff es Bool
isTracingEnabled = do
  TracingRep {tracingEnabled} <- getStaticRep
  pure tracingEnabled

-- | Run an action with an extracted parent context.
-- Use this to link spans to parent traces from message headers.
--
-- Example:
--
-- @
-- let parentCtx = extractTraceContext messageHeaders
-- withExtractedContext parentCtx $ do
--   withSpan "child.span" consumerSpanArgs $ do
--     -- this span will be a child of parentCtx
-- @
withExtractedContext ::
  (Tracing :> es, IOE :> es) =>
  Maybe OTel.SpanContext ->
  Eff es a ->
  Eff es a
withExtractedContext Nothing action = action
withExtractedContext (Just parentCtx) action = do
  TracingRep {tracingEnabled} <- getStaticRep
  if not tracingEnabled
    then action
    else do
      -- Insert the parent span into thread-local context using bracket pattern
      let parentSpan = OTel.wrapSpanContext parentCtx
          newContext = Ctx.insertSpan parentSpan Ctx.empty
      withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
        bracket_
          (Ctx.attachContext newContext)
          Ctx.detachContext
          (runInIO action)

--------------------------------------------------------------------------------
-- Internal Helpers
--------------------------------------------------------------------------------

-- | Create a dummy/dropped span for use when tracing is disabled.
-- All operations on this span are no-ops.
mkDummySpan :: IO OTel.Span
mkDummySpan = do
  -- Create a FrozenSpan with invalid (all-zeros) IDs
  -- This creates a "Dropped" span that no-ops all operations
  let dummyTraceId = case OTel.Id.bytesToTraceId (BS.replicate 16 0) of
        Right tid -> tid
        Left _ -> error "mkDummySpan: failed to create dummy TraceId"
      dummySpanId = case OTel.Id.bytesToSpanId (BS.replicate 8 0) of
        Right sid -> sid
        Left _ -> error "mkDummySpan: failed to create dummy SpanId"
      dummySpanContext =
        OTel.SpanContext
          { OTel.traceFlags = OTel.defaultTraceFlags,
            OTel.isRemote = False,
            OTel.traceId = dummyTraceId,
            OTel.spanId = dummySpanId,
            OTel.traceState = OTel.TraceState.empty
          }
  pure $ OTel.wrapSpanContext dummySpanContext
