-- | Handler overhead benchmarks.
-- Measures the overhead of different handler patterns.
module Bench.Handler (benchmarks) where

import Control.DeepSeq (NFData)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import GHC.Generics (Generic)
import Shibuya.Adapter.Mock (listAdapter, newTrackingAck, trackingAckHandle)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Runner.Supervised (runWithMetrics)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)

-- | Simple message type for benchmarking
data BenchMessage = BenchMessage
  { msgId :: !Int,
    msgPayload :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

benchmarks :: Benchmark
benchmarks =
  bgroup
    "handler-overhead"
    [ noopHandlerBenchmarks,
      computeHandlerBenchmarks,
      ioHandlerBenchmarks
    ]

-- | Minimal handler that does nothing
noopHandlerBenchmarks :: Benchmark
noopHandlerBenchmarks =
  bgroup
    "noop-handler"
    [ bench "100-msgs" $ nfIO $ runWithHandler noopHandler 100,
      bench "1000-msgs" $ nfIO $ runWithHandler noopHandler 1000,
      bench "10000-msgs" $ nfIO $ runWithHandler noopHandler 10000
    ]

-- | Handler that performs some computation
computeHandlerBenchmarks :: Benchmark
computeHandlerBenchmarks =
  bgroup
    "compute-handler"
    [ bench "light-100" $ nfIO $ runWithHandler lightComputeHandler 100,
      bench "light-1000" $ nfIO $ runWithHandler lightComputeHandler 1000,
      bench "medium-100" $ nfIO $ runWithHandler mediumComputeHandler 100,
      bench "medium-1000" $ nfIO $ runWithHandler mediumComputeHandler 1000
    ]

-- | Handler that performs IO operations
ioHandlerBenchmarks :: Benchmark
ioHandlerBenchmarks =
  bgroup
    "io-handler"
    [ bench "counter-100" $ nfIO $ runCountingHandler 100,
      bench "counter-1000" $ nfIO $ runCountingHandler 1000,
      bench "counter-10000" $ nfIO $ runCountingHandler 10000
    ]

-- | Minimal no-op handler
noopHandler :: (IOE :> es) => Handler es BenchMessage
noopHandler _ingested = pure AckOk

-- | Light computation handler
lightComputeHandler :: (IOE :> es) => Handler es BenchMessage
lightComputeHandler ingested = do
  let result = ingested.envelope.payload.msgId * 2
  result `seq` pure AckOk

-- | Medium computation handler (sum of payload chars)
mediumComputeHandler :: (IOE :> es) => Handler es BenchMessage
mediumComputeHandler ingested = do
  let payload = ingested.envelope.payload.msgPayload
      result = Text.length payload * ingested.envelope.payload.msgId
  result `seq` pure AckOk

-- | Run framework with a specific handler
runWithHandler :: (forall es. (IOE :> es) => Handler es BenchMessage) -> Int -> IO Int
runWithHandler handler n = runEff $ runTracingNoop $ do
  msgs <- createIngestedMessages n
  let adapter = listAdapter msgs
  -- inbox size must be >= message count for runWithMetrics (sequential ingestion)
  _ <- runWithMetrics (fromIntegral n) (ProcessorId "bench") adapter handler
  pure n

-- | Run with counting handler (includes IO overhead)
runCountingHandler :: Int -> IO Int
runCountingHandler n = do
  counterRef <- newIORef (0 :: Int)
  runEff $ runTracingNoop $ do
    msgs <- createIngestedMessages n

    let handler :: (IOE :> es) => Handler es BenchMessage
        handler _ingested = do
          liftIO $ atomicModifyIORef' counterRef (\c -> (c + 1, ()))
          pure AckOk

    let adapter = listAdapter msgs
    -- inbox size must be >= message count for runWithMetrics (sequential ingestion)
    _ <- runWithMetrics (fromIntegral n) (ProcessorId "bench") adapter handler

    liftIO $ readIORef counterRef

-- | Create ingested messages for testing
createIngestedMessages :: (IOE :> es) => Int -> Eff es [Ingested es BenchMessage]
createIngestedMessages n = do
  now <- liftIO getCurrentTime
  tracking <- newTrackingAck
  pure
    [ mkIngested tracking now i
    | i <- [1 .. n]
    ]
  where
    mkIngested tracking now i =
      let msgId' = MessageId $ Text.pack $ show i
          envelope =
            Envelope
              { messageId = msgId',
                cursor = Nothing,
                partition = Nothing,
                enqueuedAt = Just now,
                traceContext = Nothing,
                payload = BenchMessage i (Text.pack $ "payload-" <> show i)
              }
       in Ingested
            { envelope = envelope,
              ack = trackingAckHandle tracking msgId',
              lease = Nothing
            }
