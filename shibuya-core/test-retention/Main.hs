{-# LANGUAGE OverloadedStrings #-}

-- | Trace retention probes.
--
-- This program owns its process (see ADR 0001): weak-pointer and live-bytes
-- assertions depend on major collections and on nothing else in the process
-- holding references, so they cannot share a process with the hspec suite.
--
-- Check A: a finished span, held by an exporter, does not keep the message
-- that produced it alive.
--
-- Check B: live heap after processing ten times as many traced messages is
-- not materially larger.
--
-- Each check prints one PASS/FAIL line; the program exits non-zero if any
-- check fails.
module Main (main) where

import Control.Exception (evaluate)
import Control.Monad (forM, unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.IORef (IORef, atomicModifyIORef', mkWeakIORef, newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.Maybe (isJust)
import Data.Text qualified as Text
import Data.Word (Word8)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Exception qualified as Exception
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats)
import OpenTelemetry.Attributes (emptyAttributes)
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Processor.Span (FlushResult (..), ShutdownResult (..), SpanProcessor (..))
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Adapter (Adapter (..), defaultAdapterTelemetry)
import Shibuya.App
  ( QueueProcessor (..),
    ackAllOk,
    defaultAppConfig,
    defaultBatchConfig,
    runApp,
    stopApp,
    waitApp,
  )
import Shibuya.Batch (BatchAck, BatchConfig (..), BatchInfo)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested, mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), TraceHeaders, mkEnvelope)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (Tracing, runTracing)
import Streamly.Data.Stream qualified as Stream
import System.Exit (exitFailure)
import System.Mem (performMajorGC)
import System.Mem.Weak (Weak, deRefWeak)
import System.Timeout (timeout)

data Shape = SingleSerial | SingleAsync8 | Batch
  deriving stock (Eq, Show)

shapeName :: Shape -> String
shapeName = \case
  SingleSerial -> "single-serial"
  SingleAsync8 -> "single-async8"
  Batch -> "batch"

-- | A message payload. The 'token' is the identity the weak pointer watches:
-- a weak pointer keyed on an 'IORef' follows its underlying mutable cell,
-- which the optimiser cannot copy or unbox, so a dead weak pointer means the
-- payload record really is unreachable. The 'blob' gives a retention bug a
-- visible size.
data Payload = Payload
  { blob :: !ByteString,
    token :: !(IORef ())
  }

main :: IO ()
main = do
  results <-
    sequence
      [ checkPayloadsCollected SingleSerial,
        checkPayloadsCollected Batch,
        checkLiveBytesFlat SingleSerial,
        checkLiveBytesFlat SingleAsync8,
        checkLiveBytesFlat Batch
      ]
  unless (and results) exitFailure

--------------------------------------------------------------------------------
-- Check A
--------------------------------------------------------------------------------

payloadCount :: Int
payloadCount = 8

checkPayloadsCollected :: Shape -> IO Bool
checkPayloadsCollected shape = bounded label $ do
  (processor, exported) <- inMemoryListExporter
  provider <- OTel.createTracerProvider [processor] OTel.emptyTracerProviderOptions
  let tracer = OTel.makeTracer provider (OTel.InstrumentationLibrary "trace-retention-test" "" "" emptyAttributes) OTel.tracerOptions
  batches <- newIORef (0 :: Int)
  weaks <- runPayloadCase tracer shape batches
  performMajorGC
  performMajorGC
  alive <- length . filter isJust <$> traverse deRefWeak weaks
  -- Read the exporter only after collection, so it is demonstrably still
  -- reachable (and still holds every finished span) while the payloads die.
  spans <- readIORef exported
  let consumerSpans = length [() | sp <- spans, OTel.spanKind sp == OTel.Consumer]
  batchCount <- readIORef batches
  let expectedConsumer = if shape == Batch then batchCount else payloadCount
  void $ OTel.shutdownTracerProvider provider (Just 1_000_000)
  report
    label
    (alive == 0 && consumerSpans == expectedConsumer && expectedConsumer > 0)
    ( show consumerSpans
        <> " Consumer spans (expected "
        <> show expectedConsumer
        <> "), "
        <> show (length spans)
        <> " exported in total, "
        <> show (payloadCount - alive)
        <> " of "
        <> show payloadCount
        <> " payloads collected"
    )
  where
    label = shapeName shape <> ": finished spans do not retain payloads"

-- | Build the messages, process them to completion, and return only the weak
-- pointers. Everything else this case allocated, including the application
-- handle (whose adapter still references the message list), is unreachable
-- once it returns.
runPayloadCase :: OTel.Tracer -> Shape -> IORef Int -> IO [Weak (IORef ())]
runPayloadCase tracer shape batches = do
  built <- forM [1 .. payloadCount] $ \i -> do
    token <- newIORef ()
    weak <- mkWeakToken token
    let payload = Payload {blob = BS.replicate (1024 * 1024) (fromIntegral i :: Word8), token}
    pure (weak, message i payload)
  let weaks = map fst built
      adapter =
        Adapter
          { adapterName = "trace-retention:payload",
            source = Stream.fromList (map snd built),
            shutdown = pure (),
            telemetry = defaultAdapterTelemetry
          }
  -- Force the weak pointers out of their tuples now; returning the lazy
  -- @map fst built@ would keep the whole message list reachable.
  mapM_ evaluate weaks
  runEff $ runTracing tracer $ runToCompletion shape batches adapter
  pure weaks
{-# NOINLINE runPayloadCase #-}

mkWeakToken :: IORef () -> IO (Weak (IORef ()))
mkWeakToken ref = mkWeakIORef ref (pure ())

--------------------------------------------------------------------------------
-- Check B
--------------------------------------------------------------------------------

smallRun :: Int
smallRun = 20_000

checkLiveBytesFlat :: Shape -> IO Bool
checkLiveBytesFlat shape = bounded label $ do
  -- No exporter retains finished spans; a single discarding processor is
  -- needed only because hs-opentelemetry makes spans non-recording when a
  -- provider has no processors at all.
  provider <- OTel.createTracerProvider [discardProcessor] OTel.emptyTracerProviderOptions
  let tracer = OTel.makeTracer provider (OTel.InstrumentationLibrary "trace-retention-test" "" "" emptyAttributes) OTel.tracerOptions
  runSmallMessages tracer shape smallRun
  before <- liveBytesAfterGC
  runSmallMessages tracer shape (10 * smallRun)
  after <- liveBytesAfterGC
  void $ OTel.shutdownTracerProvider provider (Just 1_000_000)
  let allowed = before + 1024 * 1024 + before `div` 10
  report
    label
    (after <= allowed)
    ( "N="
        <> show smallRun
        <> " -> "
        <> show (10 * smallRun)
        <> ", live bytes "
        <> show before
        <> " -> "
        <> show after
        <> " (limit "
        <> show allowed
        <> ")"
    )
  where
    label = shapeName shape <> ": live bytes flat"

runSmallMessages :: OTel.Tracer -> Shape -> Int -> IO ()
runSmallMessages tracer shape n = do
  batches <- newIORef (0 :: Int)
  let adapter =
        Adapter
          { adapterName = "trace-retention:flat",
            -- A generator, not a list, so the source itself retains nothing.
            source = fmap (\i -> message i (Text.pack (show i))) (Stream.enumerateFromTo 1 n),
            shutdown = pure (),
            telemetry = defaultAdapterTelemetry
          }
  runEff $ runTracing tracer $ runToCompletion shape batches adapter
{-# NOINLINE runSmallMessages #-}

liveBytesAfterGC :: IO Integer
liveBytesAfterGC = do
  performMajorGC
  performMajorGC
  stats <- getRTSStats
  pure $ fromIntegral (gcdetails_live_bytes (gc stats))

discardProcessor :: SpanProcessor
discardProcessor =
  SpanProcessor
    { spanProcessorOnStart = \_ _ -> pure (),
      spanProcessorOnEnd = \_ -> pure (),
      spanProcessorShutdown = pure ShutdownSuccess,
      spanProcessorForceFlush = pure FlushSuccess
    }

--------------------------------------------------------------------------------
-- Shared
--------------------------------------------------------------------------------

-- | Run one processor over the adapter until its source is exhausted, then
-- stop the application so no runner thread outlives the call.
runToCompletion ::
  (IOE :> es, Tracing :> es) =>
  Shape ->
  IORef Int ->
  Adapter es msg ->
  Eff es ()
runToCompletion shape batches adapter = do
  let processor = case shape of
        SingleSerial -> QueueProcessor adapter (\_ -> pure AckOk) Unordered Serial
        SingleAsync8 -> QueueProcessor adapter (\_ -> pure AckOk) Unordered (Async 8)
        Batch -> BatchingProcessor adapter (countBatch batches) defaultBatchConfig {batchSize = 100} Unordered Serial
  runApp defaultAppConfig [(ProcessorId "trace-retention", processor)] >>= \case
    Left err -> liftIO $ fail ("runApp failed: " <> show err)
    Right app -> Exception.finally (waitApp app) (stopApp app)

countBatch :: (IOE :> es) => IORef Int -> BatchInfo -> NonEmpty a -> Eff es BatchAck
countBatch batches _ _ = do
  liftIO $ atomicModifyIORef' batches (\n -> (n + 1, ()))
  pure ackAllOk

message :: (IOE :> es) => Int -> msg -> Ingested es msg
message i payload =
  let envelope = (mkEnvelope (MessageId (Text.pack (show i))) payload) {traceContext = Just traceHeaders}
   in mkIngested envelope (AckHandle (\_ -> pure ()))

traceHeaders :: TraceHeaders
traceHeaders = [("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")]

bounded :: String -> IO Bool -> IO Bool
bounded label check =
  timeout 60_000_000 check >>= \case
    Just ok -> pure ok
    Nothing -> report label False "timed out after 60 seconds"

report :: String -> Bool -> String -> IO Bool
report label ok detail = do
  putStrLn ((if ok then "PASS: " else "FAIL: ") <> label <> " (" <> detail <> ")")
  pure ok
