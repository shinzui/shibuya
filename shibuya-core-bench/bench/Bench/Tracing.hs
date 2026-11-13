-- | Tracing-path benchmarks.
--
-- Every other group in this package runs under 'runTracingNoop', so none of
-- them measures span construction or incoming trace-header handling. This
-- group is the matrix used as the performance baseline for the trace
-- correlation work (docs/masterplans/8-configurable-trace-correlation-for-consumer-spans.md):
--
-- * tracing disabled ('runTracingNoop') or enabled ('runTracing' with a real
--   tracer whose provider has one span processor that discards every span);
-- * messages without trace headers, or all carrying one fixed valid
--   @traceparent@;
-- * single-message 'Serial', single-message @'Async' 8@, and a batching
--   processor with batch size 100.
--
-- Cell names are part of the comparison contract between plans: later plans
-- may add cells but must not rename or remove these.
module Bench.Tracing
  ( benchmarks,
    newBenchTracer,
  )
where

import Control.DeepSeq (NFData, deepseq)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Exception qualified as Exception
import GHC.Generics (Generic)
import Numeric (showHex)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Processor.Span (FlushResult (..), ShutdownResult (..), SpanProcessor (..))
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Adapter (Adapter (..), AdapterTelemetry (traceCorrelation), TraceCorrelation (..), defaultAdapterTelemetry)
import Shibuya.Adapter.Mock (listAdapter)
import Shibuya.App
  ( ProcessorMetrics (..),
    QueueProcessor (..),
    ackAllOk,
    defaultAppConfig,
    defaultBatchConfig,
    runApp,
    stopApp,
    waitApp,
  )
import Shibuya.Batch (BatchConfig (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested, mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..), StreamStats (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), TraceHeaders, mkEnvelope)
import Shibuya.Internal.App (AppHandle (..))
import Shibuya.Internal.Runner.Supervised (getMetrics)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (Tracing, runTracing, runTracingNoop)
import Test.Tasty.Bench (Benchmark, bench, bgroup, env, nfIO)

data BenchMessage = BenchMessage
  { msgId :: !Int,
    msgPayload :: !Text,
    -- | Per-message trace headers, built in 'env' outside the measurement.
    -- Only the @*-distinct@ cells read it; the others use 'Nothing' or the
    -- shared 'fixedTraceHeaders'.
    msgTrace :: !(Maybe TraceHeaders)
  }
  deriving stock (Generic)
  deriving anyclass (NFData)

data TracingMode = Disabled | Enabled

-- | 'DistinctHeaders' gives every message its own valid producer context, so
-- batch spans carry one link per member up to the bound.
data HeaderMode = NoHeaders | WithHeaders | DistinctHeaders

data Shape = SingleSerial | SingleAsync8 | Batch100 | Batch1000
  deriving stock (Eq)

messageCount :: Int
messageCount = 10_000

-- | A tracer whose provider has a single processor that discards every span.
--
-- hs-opentelemetry makes every span non-recording when a provider has no
-- processors at all, so the processor is needed for the SDK to do its full
-- span construction. Discarding (rather than exporting or keeping spans in
-- memory) keeps the measurement free of I/O, background threads, and heap
-- growth across iterations.
--
-- Fails loudly if the spans are not recording, because then the enabled
-- cells would silently measure the non-recording path instead.
newBenchTracer :: IO OTel.Tracer
newBenchTracer = do
  provider <- OTel.createTracerProvider [discardProcessor] OTel.emptyTracerProviderOptions
  let tracer = OTel.makeTracer provider instrumentationLib OTel.tracerOptions
  recording <- OTel.inSpan' tracer "bench.recording-check" OTel.defaultSpanArguments OTel.isRecording
  unless recording $
    fail "Bench.Tracing: spans from the bench tracer are not recording"
  pure tracer
  where
    instrumentationLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = "shibuya-core-bench",
          OTel.libraryVersion = "",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }

discardProcessor :: SpanProcessor
discardProcessor =
  SpanProcessor
    { spanProcessorOnStart = \_ _ -> pure (),
      spanProcessorOnEnd = \_ -> pure (),
      spanProcessorShutdown = pure ShutdownSuccess,
      spanProcessorForceFlush = pure FlushSuccess
    }

benchmarks :: OTel.Tracer -> Benchmark
benchmarks tracer =
  bgroup
    "tracing"
    [ shapeGroup "single-serial" SingleSerial,
      shapeGroup "single-async8" SingleAsync8,
      shapeGroup "batch100" Batch100,
      -- Added by docs/plans/56-…: 1,000 distinct producers per batch, so the
      -- 128-link bound and the overflow count are exercised.
      bgroup "batch1000" [cell "enabled-headers-distinct" Enabled DistinctHeaders ParentAndLink Batch1000]
    ]
  where
    shapeGroup name shape =
      bgroup name $
        [ cell "disabled-noheaders" Disabled NoHeaders ParentAndLink shape,
          cell "disabled-headers" Disabled WithHeaders ParentAndLink shape,
          cell "enabled-noheaders" Enabled NoHeaders ParentAndLink shape,
          cell "enabled-headers" Enabled WithHeaders ParentAndLink shape
        ]
          -- Added by docs/plans/55-…: the same messages under the LinkOnly
          -- policy, which roots each span instead of parenting it. Batch spans
          -- take no policy, so the batch shape has no such cell.
          <> [ cell "enabled-headers-linkonly" Enabled WithHeaders LinkOnly shape
             | shape /= Batch100
             ]
          -- Added by docs/plans/56-…: one distinct producer per member, one link each.
          <> [ cell "enabled-headers-distinct" Enabled DistinctHeaders ParentAndLink shape
             | shape == Batch100
             ]

    cell name mode headers correlation shape =
      env (pure $ createBenchMessages headers messageCount) $ \payloads ->
        bench name $
          nfIO $
            -- Force the env value outside any STM transaction first; see the
            -- EP-29 note in "Bench.Framework".
            payloads `deepseq`
              runCell tracer mode headers correlation shape payloads

runCell :: OTel.Tracer -> TracingMode -> HeaderMode -> TraceCorrelation -> Shape -> [BenchMessage] -> IO Int
runCell tracer mode headers correlation shape payloads = case mode of
  Disabled -> runEff $ runTracingNoop $ runShape headers correlation shape payloads
  Enabled -> runEff $ runTracing tracer $ runShape headers correlation shape payloads

runShape ::
  (IOE :> es, Tracing :> es) =>
  HeaderMode ->
  TraceCorrelation ->
  Shape ->
  [BenchMessage] ->
  Eff es Int
runShape headers correlation shape payloads = do
  let adapter =
        (listAdapter (createIngestedMessages headers payloads))
          { telemetry = defaultAdapterTelemetry {traceCorrelation = correlation}
          }
      processor = case shape of
        SingleSerial -> QueueProcessor adapter noopHandler Unordered Serial
        SingleAsync8 -> QueueProcessor adapter noopHandler Unordered (Async 8)
        Batch100 ->
          BatchingProcessor
            adapter
            (\_ _ -> pure ackAllOk)
            defaultBatchConfig {batchSize = 100}
            Unordered
            Serial
        Batch1000 ->
          BatchingProcessor
            adapter
            (\_ _ -> pure ackAllOk)
            defaultBatchConfig {batchSize = 1000}
            Unordered
            Serial
  runApp defaultAppConfig [(ProcessorId "tracing", processor)] >>= \case
    Left err -> liftIO $ fail ("Bench.Tracing: runApp failed: " <> show err)
    Right app -> Exception.finally (waitAndCount app) (stopApp app)

waitAndCount :: (IOE :> es) => AppHandle es -> Eff es Int
waitAndCount app = do
  waitApp app
  -- The master's live registry drops finished processors, so read each
  -- processor's own metrics handle.
  metrics <- traverse (getMetrics . fst) (foldr (:) [] app.processors)
  let processed = sum [stats.processed | ProcessorMetrics {stats} <- metrics]
  unless (processed == messageCount) $
    liftIO $
      fail ("Bench.Tracing: processed " <> show processed <> " of " <> show messageCount)
  pure processed

noopHandler :: (Applicative m) => a -> m AckDecision
noopHandler _ = pure AckOk

-- | One fixed, well-formed W3C trace context shared by every message, so
-- input construction does not vary between header cells.
fixedTraceHeaders :: TraceHeaders
fixedTraceHeaders = [("traceparent", fixedTraceparent)]

fixedTraceparent :: ByteString
fixedTraceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"

benchTime :: UTCTime
benchTime = UTCTime (fromGregorian 2024 1 1) 0

createBenchMessages :: HeaderMode -> Int -> [BenchMessage]
createBenchMessages headers n =
  [BenchMessage i (Text.pack $ "payload-" <> show i) (distinct i) | i <- [1 .. n]]
  where
    distinct i = case headers of
      DistinctHeaders -> Just (distinctTraceHeaders i)
      _ -> Nothing

-- | A valid W3C context unique to message @i@.
distinctTraceHeaders :: Int -> TraceHeaders
distinctTraceHeaders i =
  [("traceparent", BS8.pack ("00-" <> hex 32 (i + 0x1000) <> "-" <> hex 16 (i + 0x1000) <> "-01"))]
  where
    hex width n = let digits = showHex n "" in replicate (width - length digits) '0' <> digits

createIngestedMessages :: (IOE :> es) => HeaderMode -> [BenchMessage] -> [Ingested es BenchMessage]
createIngestedMessages headers = map createMessage
  where
    traceContextOf = case headers of
      NoHeaders -> const Nothing
      WithHeaders -> const (Just fixedTraceHeaders)
      DistinctHeaders -> (.msgTrace)
    createMessage payload =
      let msgId' = MessageId $ Text.pack $ show payload.msgId
          envelope = (mkEnvelope msgId' payload) {enqueuedAt = Just benchTime, traceContext = traceContextOf payload}
          ackHandle = AckHandle $ \_ -> pure ()
       in mkIngested envelope ackHandle
