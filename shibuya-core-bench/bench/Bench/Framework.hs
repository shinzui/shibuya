-- | Framework overhead benchmarks.
-- Measures the overhead of running messages through shibuya vs pure streamly.
module Bench.Framework (benchmarks) where

import Control.DeepSeq (NFData, deepseq)
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
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Tasty.Bench (Benchmark, bcompare, bench, bgroup, env, nfIO)

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
    "framework-overhead"
    [ adapterCreationBenchmarks,
      processingBenchmarks,
      comparisonBenchmarks
    ]

adapterCreationBenchmarks :: Benchmark
adapterCreationBenchmarks =
  bgroup
    "adapter-creation"
    [ bench "mock-adapter-100" $ nfIO $ createMockAdapter 100,
      bench "mock-adapter-1000" $ nfIO $ createMockAdapter 1000,
      bench "mock-adapter-10000" $ nfIO $ createMockAdapter 10000
    ]

processingBenchmarks :: Benchmark
processingBenchmarks =
  bgroup
    "processing"
    [ env (setupMessages 100) $ \msgs ->
        bench "runWithMetrics-100" $ nfIO $ runShibuyaWithMessages msgs,
      env (setupMessages 1000) $ \msgs ->
        bench "runWithMetrics-1000" $ nfIO $ runShibuyaWithMessages msgs,
      env (setupMessages 10000) $ \msgs ->
        bench "runWithMetrics-10000" $ nfIO $ runShibuyaWithMessages msgs
    ]

-- | Compare shibuya overhead vs pure streamly baseline
comparisonBenchmarks :: Benchmark
comparisonBenchmarks =
  bgroup
    "comparison"
    [ bgroup
        "100-msgs"
        [ bench "streamly-baseline" $ nfIO $ streamlyBaseline 100,
          bcompare "$NF == \"streamly-baseline\" && $(NF-1) == \"100-msgs\"" $
            bench "shibuya-framework" $
              nfIO $
                runShibuyaProcessing 100
        ],
      bgroup
        "1000-msgs"
        [ bench "streamly-baseline" $ nfIO $ streamlyBaseline 1000,
          bcompare "$NF == \"streamly-baseline\" && $(NF-1) == \"1000-msgs\"" $
            bench "shibuya-framework" $
              nfIO $
                runShibuyaProcessing 1000
        ],
      bgroup
        "10000-msgs"
        [ bench "streamly-baseline" $ nfIO $ streamlyBaseline 10000,
          bcompare "$NF == \"streamly-baseline\" && $(NF-1) == \"10000-msgs\"" $
            bench "shibuya-framework" $
              nfIO $
                runShibuyaProcessing 10000
        ]
    ]

-- | Create a mock adapter with n messages
-- Measures the cost of creating ingested messages and adapter
createMockAdapter :: Int -> IO Int
createMockAdapter n = do
  payloads <- setupMessages n
  runEff $ do
    msgs <- wrapAsIngested payloads
    let _adapter = listAdapter msgs
    -- Force every envelope so the library-provided NFData instances for
    -- Envelope, MessageId, and Cursor are exercised. If someone deletes
    -- those instances from Shibuya.Core.Types this line stops compiling.
    map (.envelope) msgs `deepseq` pure (length msgs)

-- | Run messages through shibuya framework
runShibuyaProcessing :: Int -> IO Int
runShibuyaProcessing n = runShibuyaWithMessages =<< setupMessages n

-- | Pre-create message payloads (the expensive part)
setupMessages :: Int -> IO [BenchMessage]
setupMessages n = pure [BenchMessage i (Text.pack $ "payload-" <> show i) | i <- [1 .. n]]

-- | Run pre-created messages through shibuya
runShibuyaWithMessages :: [BenchMessage] -> IO Int
runShibuyaWithMessages payloads = do
  -- Create counter for processed messages
  counterRef <- newIORef (0 :: Int)

  runEff $ runTracingNoop $ do
    -- Wrap payloads as Ingested messages
    msgs <- wrapAsIngested payloads
    let adapter = listAdapter msgs

    -- Simple handler that just counts
    let handler :: (IOE :> es) => Handler es BenchMessage
        handler _ingested = do
          liftIO $ atomicModifyIORef' counterRef (\c -> (c + 1, ()))
          pure AckOk

    -- Run through framework
    -- NOTE: inbox size must be >= message count for runWithMetrics
    -- because it runs ingester sequentially before draining
    let inboxSize = fromIntegral $ length payloads
    _ <- runWithMetrics inboxSize (ProcessorId "bench") adapter handler

    -- Return count
    liftIO $ readIORef counterRef

-- | Wrap payloads as Ingested messages
wrapAsIngested :: (IOE :> es) => [BenchMessage] -> Eff es [Ingested es BenchMessage]
wrapAsIngested payloads = do
  now <- liftIO getCurrentTime
  tracking <- newTrackingAck
  pure [mkIngested tracking now i p | (i, p) <- zip [(1 :: Int) ..] payloads]
  where
    mkIngested tracking now i payload =
      let msgId = MessageId $ Text.pack $ show i
          envelope =
            Envelope
              { messageId = msgId,
                cursor = Nothing,
                partition = Nothing,
                enqueuedAt = Just now,
                traceContext = Nothing,
                attempt = Nothing,
                payload = payload
              }
       in Ingested
            { envelope = envelope,
              ack = trackingAckHandle tracking msgId,
              lease = Nothing
            }

-- | Pure streamly baseline for comparison
streamlyBaseline :: Int -> IO Int
streamlyBaseline n = do
  counterRef <- newIORef (0 :: Int)
  let msgs = [BenchMessage i (Text.pack $ "payload-" <> show i) | i <- [1 .. n]]
  Stream.fold Fold.drain $ Stream.mapM (processMsg counterRef) $ Stream.fromList msgs
  readIORef counterRef
  where
    processMsg ref msg = do
      atomicModifyIORef' ref (\c -> (c + 1, ()))
      msg `deepseq` pure ()
