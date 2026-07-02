-- | Hot-path throughput benchmarks.
-- Measures the framework's per-message overhead with a no-op handler.
module Bench.HotPath (benchmarks) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.DeepSeq (NFData)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import GHC.Generics (Generic)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested, mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..), ProcessorMetrics (..), StreamStats (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Handler (Handler)
import Shibuya.Internal.Runner.Master (startMaster, stopMaster)
import Shibuya.Internal.Runner.Supervised (SupervisedProcessor, getMetrics, isDone, runSupervised)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Tasty.Bench (Benchmark, bench, bgroup, env, nfIO)

data BenchMessage = BenchMessage
  { msgId :: !Int,
    msgPayload :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (NFData)

benchmarks :: Benchmark
benchmarks =
  bgroup
    "hot-path"
    [ env (pure $ createBenchMessages 10_000) $ \payloads ->
        bench "serial-noop-10000" $
          nfIO $
            runHotPath Serial payloads,
      env (pure $ createBenchMessages 10_000) $ \payloads ->
        bench "async8-noop-10000" $
          nfIO $
            runHotPath (Async 8) payloads
    ]

runHotPath :: Concurrency -> [BenchMessage] -> IO Int
runHotPath concurrency payloads =
  runEff $ runTracingNoop $ do
    let msgs = createIngestedMessages payloads
    let adapter =
          Adapter
            { adapterName = "bench:hot-path",
              source = Stream.fromList msgs,
              shutdown = pure ()
            }
    master <- startMaster IgnoreAll
    sp <- runSupervised master 100 (ProcessorId "hot-path") Unordered concurrency adapter noopHandler
    waitForDone sp
    metrics :: ProcessorMetrics <- getMetrics sp
    stopMaster master
    let stats :: StreamStats
        stats = metrics.stats
    pure stats.processed

waitForDone :: (IOE :> es) => SupervisedProcessor -> Eff es ()
waitForDone sp = go
  where
    go = do
      done <- isDone sp
      if done
        then pure ()
        else do
          liftIO $ threadDelay 100
          go

noopHandler :: Handler es BenchMessage
noopHandler _ = pure AckOk

benchTime :: UTCTime
benchTime = UTCTime (fromGregorian 2024 1 1) 0

createBenchMessages :: Int -> [BenchMessage]
createBenchMessages n = [BenchMessage i (Text.pack $ "payload-" <> show i) | i <- [1 .. n]]

createIngestedMessages :: [BenchMessage] -> [Ingested es BenchMessage]
createIngestedMessages = map createMessage
  where
    createMessage payload =
      let msgId' = MessageId $ Text.pack $ show payload.msgId
          envelope = (mkEnvelope msgId' payload) {enqueuedAt = Just benchTime}
          ackHandle = AckHandle $ \_ -> pure ()
       in mkIngested envelope ackHandle
