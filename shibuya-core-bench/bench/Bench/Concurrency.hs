-- | Concurrency mode benchmarks.
-- Compares Serial, Ahead, and Async processing modes to measure
-- throughput gains from concurrent handler execution.
module Bench.Concurrency (benchmarks) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.DeepSeq (NFData)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import GHC.Generics (Generic)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Runner.Master (startMaster, stopMaster)
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Runner.Supervised (SupervisedProcessor, isDone, runSupervised, runWithMetrics)
import Streamly.Data.Stream qualified as Stream
import Test.Tasty.Bench (Benchmark, bcompare, bench, bgroup, nfIO)

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
    "concurrency-modes"
    [ cpuBoundBenchmarks,
      ioBoundBenchmarks,
      concurrencyLevelBenchmarks
    ]

-- | CPU-bound (fast) handlers - Serial mode only.
-- Concurrent modes don't benefit from CPU-bound work and are not designed
-- for zero-I/O handlers. This benchmark measures Serial processing overhead.
cpuBoundBenchmarks :: Benchmark
cpuBoundBenchmarks =
  bgroup
    "cpu-bound-serial"
    [ bench "1000-msgs" $ nfIO $ runWithConcurrency Serial cpuBoundHandler 1000,
      bench "10000-msgs" $ nfIO $ runWithConcurrency Serial cpuBoundHandler 10000
    ]

-- | Compare modes with IO-bound (slow) handlers
-- Here concurrency should show significant speedup
ioBoundBenchmarks :: Benchmark
ioBoundBenchmarks =
  bgroup
    "io-bound"
    [ bgroup
        "100-msgs-1ms-delay"
        [ bench "serial" $ nfIO $ runWithConcurrency Serial (ioBoundHandler 1000) 100,
          bcompare "$NF == \"serial\" && $(NF-1) == \"100-msgs-1ms-delay\"" $
            bench "ahead-5" $
              nfIO $
                runWithConcurrency (Ahead 5) (ioBoundHandler 1000) 100,
          bcompare "$NF == \"serial\" && $(NF-1) == \"100-msgs-1ms-delay\"" $
            bench "async-5" $
              nfIO $
                runWithConcurrency (Async 5) (ioBoundHandler 1000) 100,
          bcompare "$NF == \"serial\" && $(NF-1) == \"100-msgs-1ms-delay\"" $
            bench "async-10" $
              nfIO $
                runWithConcurrency (Async 10) (ioBoundHandler 1000) 100
        ],
      bgroup
        "50-msgs-5ms-delay"
        [ bench "serial" $ nfIO $ runWithConcurrency Serial (ioBoundHandler 5000) 50,
          bcompare "$NF == \"serial\" && $(NF-1) == \"50-msgs-5ms-delay\"" $
            bench "ahead-5" $
              nfIO $
                runWithConcurrency (Ahead 5) (ioBoundHandler 5000) 50,
          bcompare "$NF == \"serial\" && $(NF-1) == \"50-msgs-5ms-delay\"" $
            bench "async-5" $
              nfIO $
                runWithConcurrency (Async 5) (ioBoundHandler 5000) 50,
          bcompare "$NF == \"serial\" && $(NF-1) == \"50-msgs-5ms-delay\"" $
            bench "async-10" $
              nfIO $
                runWithConcurrency (Async 10) (ioBoundHandler 5000) 50
        ]
    ]

-- | Compare different concurrency levels
concurrencyLevelBenchmarks :: Benchmark
concurrencyLevelBenchmarks =
  bgroup
    "concurrency-levels"
    [ bgroup
        "ahead-100msgs-1ms"
        [ bench "ahead-2" $ nfIO $ runWithConcurrency (Ahead 2) (ioBoundHandler 1000) 100,
          bcompare "$NF == \"ahead-2\" && $(NF-1) == \"ahead-100msgs-1ms\"" $
            bench "ahead-5" $
              nfIO $
                runWithConcurrency (Ahead 5) (ioBoundHandler 1000) 100,
          bcompare "$NF == \"ahead-2\" && $(NF-1) == \"ahead-100msgs-1ms\"" $
            bench "ahead-10" $
              nfIO $
                runWithConcurrency (Ahead 10) (ioBoundHandler 1000) 100,
          bcompare "$NF == \"ahead-2\" && $(NF-1) == \"ahead-100msgs-1ms\"" $
            bench "ahead-20" $
              nfIO $
                runWithConcurrency (Ahead 20) (ioBoundHandler 1000) 100
        ],
      bgroup
        "async-100msgs-1ms"
        [ bench "async-2" $ nfIO $ runWithConcurrency (Async 2) (ioBoundHandler 1000) 100,
          bcompare "$NF == \"async-2\" && $(NF-1) == \"async-100msgs-1ms\"" $
            bench "async-5" $
              nfIO $
                runWithConcurrency (Async 5) (ioBoundHandler 1000) 100,
          bcompare "$NF == \"async-2\" && $(NF-1) == \"async-100msgs-1ms\"" $
            bench "async-10" $
              nfIO $
                runWithConcurrency (Async 10) (ioBoundHandler 1000) 100,
          bcompare "$NF == \"async-2\" && $(NF-1) == \"async-100msgs-1ms\"" $
            bench "async-20" $
              nfIO $
                runWithConcurrency (Async 20) (ioBoundHandler 1000) 100
        ]
    ]

-- | Run benchmark with specific concurrency mode.
-- For Serial: uses runWithMetrics (simpler, no async overhead).
-- For Ahead/Async: uses runSupervised (designed for I/O-bound handlers).
runWithConcurrency :: Concurrency -> (IORef Int -> Handler '[IOE] BenchMessage) -> Int -> IO Int
runWithConcurrency concurrency mkHandler n = runEff $ do
  -- Create counter to track processed messages
  counterRef <- liftIO $ newIORef 0

  -- Create messages
  msgs <- createIngestedMessages n

  -- Create handler
  let handler = mkHandler counterRef

  -- Create adapter
  let adapter =
        Adapter
          { adapterName = "bench:list",
            source = Stream.fromList msgs,
            shutdown = pure ()
          }

  case concurrency of
    Serial -> do
      -- For Serial mode, use runWithMetrics (simpler, no async overhead)
      -- NOTE: inbox size must be >= message count for runWithMetrics
      let inboxSize = fromIntegral n
      _ <- runWithMetrics inboxSize (ProcessorId "bench") adapter handler
      pure ()
    _ -> do
      -- For concurrent modes, use runSupervised.
      -- NOTE: This requires handlers with I/O (threadDelay) to allow
      -- proper thread scheduling. CPU-bound handlers may cause STM blocking.
      master <- startMaster IgnoreAll
      sp <- runSupervised master 100 (ProcessorId "bench") concurrency adapter handler
      waitForDone sp
      stopMaster master

  liftIO $ readIORef counterRef

-- | Wait for processor to complete
waitForDone :: SupervisedProcessor -> Eff '[IOE] ()
waitForDone sp = go
  where
    go = do
      done <- isDone sp
      if done
        then pure ()
        else do
          liftIO $ threadDelay 100 -- 100μs
          go

-- | CPU-bound handler: minimal work, just ack
cpuBoundHandler :: IORef Int -> Handler '[IOE] BenchMessage
cpuBoundHandler counterRef ingested = do
  -- Light computation to prevent optimizer from eliminating the handler
  let result = ingested.envelope.payload.msgId * 2
  result `seq` pure ()

  -- Count processed messages
  _ <- liftIO $ atomicModifyIORef' counterRef (\c -> (c + 1, c + 1))

  pure AckOk

-- | IO-bound handler: simulates IO latency with threadDelay
ioBoundHandler :: Int -> IORef Int -> Handler '[IOE] BenchMessage
ioBoundHandler delayMicros counterRef _ingested = do
  liftIO $ threadDelay delayMicros

  -- Count processed messages
  _ <- liftIO $ atomicModifyIORef' counterRef (\c -> (c + 1, c + 1))

  pure AckOk

-- | Fixed time for benchmarks
benchTime :: UTCTime
benchTime = UTCTime (fromGregorian 2024 1 1) 0

-- | Create ingested messages for benchmarking
-- Effectful to ensure proper effect stack unification
createIngestedMessages :: (IOE :> es) => Int -> Eff es [Ingested es BenchMessage]
createIngestedMessages n = mapM createMessage [1 .. n]
  where
    createMessage i = do
      let msgId' = MessageId $ Text.pack $ show i
          envelope =
            Envelope
              { messageId = msgId',
                cursor = Nothing,
                partition = Nothing,
                enqueuedAt = Just benchTime,
                payload = BenchMessage i (Text.pack $ "payload-" <> show i)
              }
          ackHandle = AckHandle $ \_ -> pure () -- No-op ack
      pure $
        Ingested
          { envelope = envelope,
            ack = ackHandle,
            lease = Nothing
          }
