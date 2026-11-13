-- | Fan-in links on batch processing spans.
--
-- A batch has many producers and a span has one parent, so the batch span is
-- a root that links every member's creation context, bounded at
-- 'maxBatchLinks', each link naming its member.
module Shibuya.Telemetry.BatchCorrelationSpec (spec) where

import Control.Exception (bracket)
import Control.Monad (forM_, void)
import Data.ByteString.Char8 qualified as BS8
import Data.Foldable (toList)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Numeric (showHex)
import OpenTelemetry.Attributes (Attribute, emptyAttributes, getAttributeMap, toAttribute)
import OpenTelemetry.Context qualified as Ctx
import OpenTelemetry.Context.ThreadLocal qualified as Ctx
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id (Base (..))
import OpenTelemetry.Trace.Id qualified as OTel.Id
import OpenTelemetry.Trace.Id.Generator (IdGenerator (..))
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Shibuya.Adapter (Adapter (..), AdapterTelemetry (traceCorrelation), TraceCorrelation (..), defaultAdapterTelemetry)
import Shibuya.Adapter.Mock (listAdapter)
import Shibuya.Batch (BatchConfig (..), ackAllOk, defaultBatchConfig)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (DeliveryStatus (..), Ingested (..), mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), TraceHeaders, mkEnvelope)
import Shibuya.Internal.Runner.Supervised (runWithMetricsBatch)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Correlation (BatchLinks (..), collectBatchLinks, maxBatchLinks)
import Shibuya.Telemetry.Effect (Tracing, runTracing, runTracingNoop, withSpan')
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.Telemetry.Correlation (batches)" $ do
  describe "collectBatchLinks" $ do
    it "links members in order, each with its message id" $ do
      let result = collectBatchLinks [(MessageId "a", Just (producer 1)), (MessageId "b", Nothing), (MessageId "c", Just (producer 3))]
      map (hexSpan . (.linkContext)) result.links `shouldBe` [spanHex 1, spanHex 3]
      map (HashMap.lookup "messaging.message.id" . (.linkAttributes)) result.links
        `shouldBe` [Just (toAttribute ("a" :: Text)), Just (toAttribute ("c" :: Text))]
      result.dropped `shouldBe` 0

    it "keeps one link per member when members share a context" $ do
      let result = collectBatchLinks [(MessageId "a", Just (producer 1)), (MessageId "b", Just (producer 1))]
      map (hexSpan . (.linkContext)) result.links `shouldBe` [spanHex 1, spanHex 1]
      map (HashMap.lookup "messaging.message.id" . (.linkAttributes)) result.links
        `shouldBe` [Just (toAttribute ("a" :: Text)), Just (toAttribute ("b" :: Text))]

    it "stores at most maxBatchLinks and counts only valid omitted contexts" $ do
      let full = [(MessageId (tshow i), Just (producer i)) | i <- [1 .. maxBatchLinks]]
          tailMembers =
            [ (MessageId "absent", Nothing),
              (MessageId "malformed", Just malformed),
              (MessageId "valid-1", Just (producer 1000)),
              (MessageId "valid-2", Just (producer 1001))
            ]
          result = collectBatchLinks (full <> tailMembers)
      length result.links `shouldBe` maxBatchLinks
      result.dropped `shouldBe` 2

    it "keeps sparse valid contexts before the cap" $ do
      let members = concat [[(MessageId (tshow i), Just (producer i)), (MessageId "gap", Nothing), (MessageId "bad", Just malformed)] | i <- [1 .. 10]]
          result = collectBatchLinks members
      length result.links `shouldBe` 10
      result.dropped `shouldBe` 0

  describe "batch spans through the runner" $ do
    it "is a root with one link per producer, naming each member" $ do
      [sp] <- batchSpans =<< runBatch [member "m1" (Just (producer 1)), member "m2" (Just (producer 2)), member "m3" (Just (producer 3))]
      isNothing sp.parent `shouldBe` True
      map fst sp.links `shouldBe` [spanHex 1, spanHex 2, spanHex 3]
      map snd sp.links `shouldBe` map (Just . toAttribute) ["m1", "m2", "m3" :: Text]
      sp.traceHex `notElem` map traceHex [1, 2, 3] `shouldBe` True
      HashMap.lookup "messaging.batch.message_count" sp.attributes `shouldBe` Just (toAttribute (3 :: Int))
      sp.name `shouldBe` "process batch-correlation"
      HashMap.lookup "messaging.operation.name" sp.attributes `shouldBe` Just (toAttribute ("process" :: Text))
      HashMap.lookup "messaging.operation.type" sp.attributes `shouldBe` Just (toAttribute ("process" :: Text))
      HashMap.member "shibuya.batch.links.dropped" sp.attributes `shouldBe` False

    it "links members that share a context separately" $ do
      [sp] <- batchSpans =<< runBatch [member "m1" (Just (producer 1)), member "m2" (Just (producer 1)), member "m3" (Just (producer 3))]
      map fst sp.links `shouldBe` [spanHex 1, spanHex 1, spanHex 3]
      map snd sp.links `shouldBe` map (Just . toAttribute) ["m1", "m2", "m3" :: Text]

    it "has no links and no parent when no member has headers" $ do
      [sp] <- batchSpans =<< runBatch [member "m1" Nothing, member "m2" Nothing]
      sp.links `shouldBe` []
      isNothing sp.parent `shouldBe` True

    it "links only the members that have headers" $ do
      [sp] <- batchSpans =<< runBatch [member "m1" Nothing, member "m2" (Just (producer 2)), member "m3" (Just malformed)]
      map snd sp.links `shouldBe` [Just (toAttribute ("m2" :: Text))]

    it "bounds 200 distinct producers at 128 links and reports 72 dropped" $ do
      [sp] <- batchSpans =<< runBatch [member (tshow i) (Just (producer i)) | i <- [1 .. 200]]
      length sp.links `shouldBe` 128
      HashMap.lookup "shibuya.batch.links.dropped" sp.attributes `shouldBe` Just (toAttribute (72 :: Int))
      HashMap.lookup "messaging.batch.message_count" sp.attributes `shouldBe` Just (toAttribute (200 :: Int))

    it "does not link a superseded member" $ do
      let superseded = (member "m2" (Just (producer 2))) {deliveryStatus = pure DeliverySuperseded}
      [sp] <- batchSpans =<< runBatch [member "m1" (Just (producer 1)), superseded, member "m3" (Just (producer 3))]
      map snd sp.links `shouldBe` map (Just . toAttribute) ["m1", "m3" :: Text]
      HashMap.lookup "messaging.batch.message_count" sp.attributes `shouldBe` Just (toAttribute (2 :: Int))

    forM_ [minBound .. maxBound] $ \policy ->
      it ("ignores the adapter's " <> show policy <> " policy") $ do
        [sp] <- batchSpans =<< runBatchWith policy [member "m1" (Just (producer 1))]
        isNothing sp.parent `shouldBe` True
        map fst sp.links `shouldBe` [spanHex 1]

    it "is still a root inside an ambient span, which is restored afterwards" $ do
      restored <- newIORef False
      spans <- withExporter $ \tracer -> runEff $
        runTracing tracer $
          withSpan' "ambient" OTel.defaultSpanArguments $ \ambient -> do
            batchOnce ParentAndLink [member "m1" (Just (producer 1))]
            liftIO $ do
              ambientCtx <- OTel.getSpanContext ambient
              current <- traverse OTel.getSpanContext . Ctx.lookupSpan =<< Ctx.getContext
              writeIORef restored (current == Just ambientCtx)
      [sp] <- batchSpans spans
      isNothing sp.parent `shouldBe` True
      readIORef restored `shouldReturn` True

    it "runs the handler and exports nothing with tracing disabled" $ do
      handled <- newIORef (0 :: Int)
      spans <- withExporter $ \_ -> runEff $ runTracingNoop $ do
        let adapter = listAdapter [member "m1" (Just (producer 1))]
        void $ runWithMetricsBatch 16 (ProcessorId "batch-correlation") Serial batchConfig adapter $ \_ _ ->
          liftIO (modifyIORef' handled (+ 1)) >> pure ackAllOk
      readIORef handled `shouldReturn` 1
      length spans `shouldBe` 0

--------------------------------------------------------------------------------
-- Fixtures
--------------------------------------------------------------------------------

batchConfig :: BatchConfig es msg
batchConfig = defaultBatchConfig {batchSize = 1000, batchTimeout = 60}

member :: (IOE :> es) => Text -> Maybe TraceHeaders -> Ingested es ()
member msgId headers =
  mkIngested ((mkEnvelope (MessageId msgId) ()) {traceContext = headers}) (AckHandle (\_ -> pure ()))

-- | A distinct, valid producer context for each index.
producer :: Int -> TraceHeaders
producer i = [("traceparent", BS8.pack ("00-" <> Text.unpack (traceHex i) <> "-" <> Text.unpack (spanHex i) <> "-01"))]

malformed :: TraceHeaders
malformed = [("traceparent", "00-not-a-valid-traceparent-01")]

traceHex :: Int -> Text
traceHex i = padHex 32 (i + 0xabc)

spanHex :: Int -> Text
spanHex i = padHex 16 (i + 0x100)

padHex :: Int -> Int -> Text
padHex width n = let digits = showHex n "" in Text.pack (replicate (width - length digits) '0' <> digits)

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

batchOnce :: (IOE :> es, Tracing :> es) => TraceCorrelation -> [Ingested es ()] -> Eff es ()
batchOnce policy members =
  let adapter = (listAdapter members) {telemetry = defaultAdapterTelemetry {traceCorrelation = policy}}
   in void $ runWithMetricsBatch 16 (ProcessorId "batch-correlation") Serial batchConfig adapter (\_ _ -> pure ackAllOk)

runBatch :: [Ingested '[Tracing, IOE] ()] -> IO [OTel.ImmutableSpan]
runBatch = runBatchWith ParentAndLink

runBatchWith :: TraceCorrelation -> [Ingested '[Tracing, IOE] ()] -> IO [OTel.ImmutableSpan]
runBatchWith policy members = withExporter $ \tracer -> runEff $ runTracing tracer $ batchOnce policy members

withExporter :: (OTel.Tracer -> IO ()) -> IO [OTel.ImmutableSpan]
withExporter action = do
  (processor, spansRef) <- inMemoryListExporter
  bracket
    (OTel.createTracerProvider [processor] OTel.emptyTracerProviderOptions {OTel.tracerProviderOptionsIdGenerator = DefaultIdGenerator})
    (\provider -> void $ OTel.shutdownTracerProvider provider (Just 5_000_000))
    (\provider -> action (OTel.makeTracer provider (OTel.InstrumentationLibrary "batch-correlation-test" "" "" emptyAttributes) OTel.tracerOptions))
  readIORef spansRef

data BatchSpan = BatchSpan
  { name :: Text,
    traceHex :: Text,
    parent :: Maybe OTel.SpanContext,
    links :: [(Text, Maybe Attribute)],
    attributes :: HashMap.HashMap Text Attribute
  }

batchSpans :: [OTel.ImmutableSpan] -> IO [BatchSpan]
batchSpans spans = traverse describeSpan [sp | sp <- spans, OTel.spanKind sp == OTel.Consumer]
  where
    describeSpan sp = do
      hot <- readIORef (OTel.spanHot sp)
      parent <- traverse OTel.getSpanContext (OTel.spanParent sp)
      pure
        BatchSpan
          { name = OTel.hotName hot,
            traceHex = OTel.Id.traceIdBaseEncodedText Base16 (OTel.spanContext sp).traceId,
            parent,
            links =
              [ (hexSpan (OTel.frozenLinkContext link), HashMap.lookup "messaging.message.id" (getAttributeMap (OTel.frozenLinkAttributes link)))
              | link <- toList (appendOnlyBoundedCollectionValues (OTel.hotLinks hot))
              ],
            attributes = getAttributeMap (OTel.hotAttributes hot)
          }

hexSpan :: OTel.SpanContext -> Text
hexSpan ctx = OTel.Id.spanIdBaseEncodedText Base16 ctx.spanId
