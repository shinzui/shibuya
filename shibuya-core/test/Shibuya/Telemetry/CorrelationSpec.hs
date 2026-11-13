-- | Trace correlation policies for per-message processing spans.
--
-- Every case drives a real tracer whose provider exports into memory, and
-- inspects the exported Consumer spans: their trace, their parent, and
-- their links.
module Shibuya.Telemetry.CorrelationSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import OpenTelemetry.Attributes (emptyAttributes, getAttributeMap, toAttribute)
import OpenTelemetry.Context qualified as Ctx
import OpenTelemetry.Context.ThreadLocal qualified as Ctx
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id (Base (..))
import OpenTelemetry.Trace.Id qualified as OTel.Id
import OpenTelemetry.Trace.Id.Generator (IdGenerator (..))
import OpenTelemetry.Trace.TraceState qualified as TraceState
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Shibuya.Adapter (Adapter (..), AdapterTelemetry (traceCorrelation), TraceCorrelation (..), defaultAdapterTelemetry)
import Shibuya.Adapter.Mock (listAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (DeliveryStatus (..), Ingested (..), mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), TraceHeaders, mkEnvelope)
import Shibuya.Internal.Runner.Supervised (runWithMetrics)
import Shibuya.Telemetry.Correlation (consumerSpanArgsLinkedTo, creationLink, creationLinkWith)
import Shibuya.Telemetry.Effect (Tracing, runTracing, runTracingNoop, withSpan')
import Shibuya.Telemetry.Process (withProcessSpan, withProcessSpanIO)
import Shibuya.Telemetry.Propagation (currentTraceHeaders, extractTraceContext)
import Shibuya.Telemetry.Semantic (processSpanName)
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.Telemetry.Correlation" $ do
  describe "AdapterTelemetry" $ do
    it "defaults to ParentAndLink and is changed by record update" $ do
      defaultAdapterTelemetry.traceCorrelation `shouldBe` ParentAndLink
      (defaultAdapterTelemetry {traceCorrelation = LinkOnly}).traceCorrelation `shouldBe` LinkOnly

  describe "creationLink" $ do
    it "decodes a valid traceparent into an attribute-free link" $
      case creationLink producerHeaders of
        Nothing -> expectationFailure "expected a link"
        Just link -> do
          hexTrace link.linkContext `shouldBe` producerTraceHex
          hexSpan link.linkContext `shouldBe` producerSpanHex
          HashMap.null link.linkAttributes `shouldBe` True

    it "keeps tracestate on the linked context" $
      case creationLink (producerHeaders <> [("tracestate", "congo=t61rcWkgMzE")]) of
        Nothing -> expectationFailure "expected a link"
        Just link -> TraceState.toList link.linkContext.traceState `shouldBe` [(TraceState.Key "congo", TraceState.Value "t61rcWkgMzE")]

    it "returns Nothing without a traceparent" $
      isNothing (creationLink [("tracestate", "congo=t61rcWkgMzE")]) `shouldBe` True

    it "returns Nothing for a malformed traceparent" $
      isNothing (creationLink malformedHeaders) `shouldBe` True

    it "carries caller-supplied attributes with creationLinkWith" $ do
      let attrs = HashMap.singleton "messaging.message.id" (toAttribute ("m-1" :: Text))
      case creationLinkWith attrs producerHeaders of
        Nothing -> expectationFailure "expected a link"
        Just link -> link.linkAttributes `shouldBe` attrs

    it "builds Consumer-kind arguments carrying the links" $ do
      let links = maybe [] pure (creationLink producerHeaders)
          args = consumerSpanArgsLinkedTo links
      args.kind `shouldBe` OTel.Consumer
      length args.links `shouldBe` 1

  describe "processing spans through the runner" $ do
    it "ParentAndLink: child of the producer, with one link to it" $ do
      [sp] <- consumerSpans =<< runMessage ParentAndLink (Just producerHeaders) Nothing
      hexTrace sp.context `shouldBe` producerTraceHex
      fmap hexSpan sp.parent `shouldBe` Just producerSpanHex
      map (\l -> (hexTrace l, hexSpan l)) sp.links `shouldBe` [(producerTraceHex, producerSpanHex)]

    it "LinkOnly: a root in a new trace, with one link to the producer" $ do
      [sp] <- consumerSpans =<< runMessage LinkOnly (Just producerHeaders) Nothing
      hexTrace sp.context `shouldNotBe` producerTraceHex
      isNothing sp.parent `shouldBe` True
      map (\l -> (hexTrace l, hexSpan l)) sp.links `shouldBe` [(producerTraceHex, producerSpanHex)]

    it "LinkOnly: still a root when an ambient span is active, which is restored afterwards" $ do
      restored <- newIORef Nothing
      spans <- withExporter $ \tracer -> runEff $
        runTracing tracer $
          withSpan' "ambient" OTel.defaultSpanArguments $ \ambient -> do
            runOnce LinkOnly (Just producerHeaders) Nothing
            liftIO $ do
              ambientCtx <- OTel.getSpanContext ambient
              current <- Ctx.lookupSpan <$> Ctx.getContext
              currentCtx <- traverse OTel.getSpanContext current
              writeIORef restored (Just (Just ambientCtx == currentCtx))
      [sp] <- consumerSpans spans
      isNothing sp.parent `shouldBe` True
      length sp.links `shouldBe` 1
      readIORef restored `shouldReturn` Just True

    forM_ [minBound .. maxBound] $ \policy -> do
      forM_ [("absent", Nothing), ("malformed", Just malformedHeaders)] $ \(label, headers) -> do
        it (show policy <> ": " <> label <> " headers keep the ambient parent and add no link") $ do
          (ambientSpanHex, spans) <- withAmbient $ \_tracer ->
            runOnce policy headers Nothing
          [sp] <- consumerSpans spans
          sp.links `shouldBe` []
          fmap hexSpan sp.parent `shouldBe` Just ambientSpanHex

        it (show policy <> ": " <> label <> " headers without an ambient span give a root") $ do
          [sp] <- consumerSpans =<< runMessage policy headers Nothing
          sp.links `shouldBe` []
          isNothing sp.parent `shouldBe` True

    it "LinkOnly: currentTraceHeaders in the handler names the new trace and the Consumer span" $ do
      seen <- newIORef Nothing
      spans <- withExporter $ \tracer ->
        runEff $
          runTracing tracer $
            runOnce LinkOnly (Just producerHeaders) (Just seen)
      [sp] <- consumerSpans spans
      Just (Just headers) <- readIORef seen
      case extractTraceContext headers of
        Nothing -> expectationFailure "handler saw no decodable traceparent"
        Just ctx -> do
          hexTrace ctx `shouldBe` hexTrace sp.context
          hexSpan ctx `shouldBe` hexSpan sp.context
          hexTrace ctx `shouldNotBe` producerTraceHex

    it "LinkOnly: a superseded delivery still opens a linked span that ends successfully" $ do
      spans <- withExporter $ \tracer -> runEff $ runTracing tracer $ do
        let message = (producedMessage (Just producerHeaders)) {deliveryStatus = pure DeliverySuperseded}
        void $ runWithMetrics 4 (ProcessorId "correlation") (policyAdapter LinkOnly [message]) (\_ -> pure AckOk)
      [sp] <- consumerSpans spans
      isNothing sp.parent `shouldBe` True
      length sp.links `shouldBe` 1
      sp.status `shouldBe` OTel.Ok
      sp.ackDecisions `shouldBe` [toAttribute ("superseded" :: Text)]

    forM_ [minBound .. maxBound] $ \policy ->
      it (show policy <> ": disabled tracing runs the handler and exports nothing") $ do
        handled <- newIORef (0 :: Int)
        spans <- withExporter $ \_tracer -> runEff $ runTracingNoop $ do
          let adapter = policyAdapter policy [producedMessage (Just producerHeaders)]
          void $ runWithMetrics 4 (ProcessorId "correlation") adapter (\_ -> liftIO (modifyIORef' handled (+ 1)) >> pure AckOk)
        readIORef handled `shouldReturn` 1
        length spans `shouldBe` 0

  describe "withProcessSpan and withProcessSpanIO called directly" $ do
    forM_ [minBound .. maxBound] $ \policy -> do
      it (show policy <> ": both give the runner's span shape") $ do
        [runner] <- consumerSpans =<< runMessage policy (Just producerHeaders) Nothing
        [effect] <- consumerSpans =<< withExporter (\tracer -> runEff $ runTracing tracer $ withProcessSpan policy processName (Just producerHeaders) (\_ -> pure ()))
        [io] <- consumerSpans =<< withExporter (\tracer -> withProcessSpanIO tracer policy processName (Just producerHeaders) (\_ -> pure ()))
        forM_ [effect, io] $ \sp -> do
          sp.name `shouldBe` runner.name
          fmap hexSpan sp.parent `shouldBe` fmap hexSpan runner.parent
          map hexSpan sp.links `shouldBe` map hexSpan runner.links
          (hexTrace sp.context == producerTraceHex) `shouldBe` (hexTrace runner.context == producerTraceHex)

      it (show policy <> ": the IO helper keeps the ambient parent without headers") $ do
        (ambientSpanHex, spans) <- withAmbient $ \tracer ->
          liftIO $ withProcessSpanIO tracer policy processName Nothing (\_ -> pure ())
        [sp] <- consumerSpans spans
        sp.links `shouldBe` []
        fmap hexSpan sp.parent `shouldBe` Just ambientSpanHex

      it (show policy <> ": withProcessSpan under runTracingNoop passes the sentinel span") $ do
        recording <- runEff $ runTracingNoop $ withProcessSpan policy processName (Just producerHeaders) (liftIO . OTel.isRecording)
        recording `shouldBe` False

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

producerTraceHex :: Text
producerTraceHex = "0af7651916cd43dd8448eb211c80319c"

producerSpanHex :: Text
producerSpanHex = "b7ad6b7169203331"

producerHeaders :: TraceHeaders
producerHeaders = [("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")]

malformedHeaders :: [(ByteString, ByteString)]
malformedHeaders = [("traceparent", "00-not-a-valid-traceparent-01")]

processName :: Text
processName = processSpanName "correlation"

producedMessage :: (IOE :> es) => Maybe TraceHeaders -> Ingested es ()
producedMessage headers =
  mkIngested ((mkEnvelope (MessageId "m-1") ()) {traceContext = headers}) (AckHandle (\_ -> pure ()))

policyAdapter :: (IOE :> es) => TraceCorrelation -> [Ingested es msg] -> Adapter es msg
policyAdapter policy messages =
  (listAdapter messages) {telemetry = defaultAdapterTelemetry {traceCorrelation = policy}}

-- | Process one message on the calling thread (the unsupervised runner path),
-- so an ambient span on this thread is visible to the processing span.
runOnce ::
  (IOE :> es, Tracing :> es) =>
  TraceCorrelation ->
  Maybe TraceHeaders ->
  Maybe (IORef (Maybe (Maybe TraceHeaders))) ->
  Eff es ()
runOnce policy headers seen =
  void $
    runWithMetrics 4 (ProcessorId "correlation") (policyAdapter policy [producedMessage headers]) $ \_ -> do
      forM_ seen $ \ref -> currentTraceHeaders >>= liftIO . writeIORef ref . Just
      pure AckOk

runMessage :: TraceCorrelation -> Maybe TraceHeaders -> Maybe (IORef (Maybe (Maybe TraceHeaders))) -> IO [OTel.ImmutableSpan]
runMessage policy headers seen =
  withExporter $ \tracer -> runEff $ runTracing tracer $ runOnce policy headers seen

-- | Run inside an ambient span and return that span's ID with the exports.
withAmbient :: (OTel.Tracer -> Eff '[Tracing, IOE] ()) -> IO (Text, [OTel.ImmutableSpan])
withAmbient action = do
  ambientRef <- newIORef ""
  spans <- withExporter $ \tracer -> runEff $
    runTracing tracer $
      withSpan' "ambient" OTel.defaultSpanArguments $ \ambient -> do
        ctx <- liftIO $ OTel.getSpanContext ambient
        liftIO $ writeIORef ambientRef (hexSpan ctx)
        action tracer
  ambientSpanHex <- readIORef ambientRef
  pure (ambientSpanHex, spans)

withExporter :: (OTel.Tracer -> IO ()) -> IO [OTel.ImmutableSpan]
withExporter action = do
  (processor, spansRef) <- inMemoryListExporter
  bracket
    (OTel.createTracerProvider [processor] OTel.emptyTracerProviderOptions {OTel.tracerProviderOptionsIdGenerator = DefaultIdGenerator})
    (\provider -> void $ OTel.shutdownTracerProvider provider (Just 5_000_000))
    (\provider -> action (OTel.makeTracer provider (OTel.InstrumentationLibrary "correlation-test" "" "" emptyAttributes) OTel.tracerOptions))
  readIORef spansRef

data ConsumerSpan = ConsumerSpan
  { name :: Text,
    context :: OTel.SpanContext,
    parent :: Maybe OTel.SpanContext,
    links :: [OTel.SpanContext],
    status :: OTel.SpanStatus,
    ackDecisions :: [OTel.Attribute]
  }

consumerSpans :: [OTel.ImmutableSpan] -> IO [ConsumerSpan]
consumerSpans spans = traverse describeSpan [sp | sp <- spans, OTel.spanKind sp == OTel.Consumer]
  where
    describeSpan sp = do
      hot <- readIORef (OTel.spanHot sp)
      parent <- traverse OTel.getSpanContext (OTel.spanParent sp)
      pure
        ConsumerSpan
          { name = OTel.hotName hot,
            context = OTel.spanContext sp,
            parent,
            links = map OTel.frozenLinkContext (toList (appendOnlyBoundedCollectionValues (OTel.hotLinks hot))),
            status = OTel.hotStatus hot,
            ackDecisions =
              [ value
              | event <- toList (appendOnlyBoundedCollectionValues (OTel.hotEvents hot)),
                OTel.eventName event == "shibuya.ack.decision",
                Just value <- [HashMap.lookup "shibuya.ack.decision" (getAttributeMap (OTel.eventAttributes event))]
              ]
          }

hexTrace :: OTel.SpanContext -> Text
hexTrace ctx = OTel.Id.traceIdBaseEncodedText Base16 ctx.traceId

hexSpan :: OTel.SpanContext -> Text
hexSpan ctx = OTel.Id.spanIdBaseEncodedText Base16 ctx.spanId
