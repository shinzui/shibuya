module Bench.Fifo (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    runSession,
    seedQueueWithHeaders,
  )
import Data.Text qualified as Text
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types (Message (..), QueueName)
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)

benchmarks :: Pool.Pool -> BenchConfig -> Benchmark
benchmarks pool config =
  bgroup
    "fifo"
    [ groupedBenchmarks pool config,
      roundRobinBenchmarks pool config,
      groupCountBenchmarks pool config
    ]

groupedBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
groupedBenchmarks pool config =
  bgroup
    "grouped"
    [ bench "read-10" $ nfIO $ withFifoQueue pool config "grp10" 5000 10 $ \q -> runReadGrouped pool q 10,
      bench "read-50" $ nfIO $ withFifoQueue pool config "grp50" 5000 10 $ \q -> runReadGrouped pool q 50
    ]

roundRobinBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
roundRobinBenchmarks pool config =
  bgroup
    "round-robin"
    [ bench "read-10" $ nfIO $ withFifoQueue pool config "rr10" 5000 10 $ \q -> runReadGroupedRR pool q 10,
      bench "read-50" $ nfIO $ withFifoQueue pool config "rr50" 5000 10 $ \q -> runReadGroupedRR pool q 50
    ]

groupCountBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
groupCountBenchmarks pool config =
  bgroup
    "group-count"
    [ bench "single-group" $ nfIO $ withFifoQueue pool config "g1" 1000 1 $ \q -> runReadGrouped pool q 50,
      bench "10-groups" $ nfIO $ withFifoQueue pool config "g10" 1000 10 $ \q -> runReadGrouped pool q 50,
      bench "100-groups" $ nfIO $ withFifoQueue pool config "g100" 1000 100 $ \q -> runReadGrouped pool q 50
    ]

withFifoQueue :: Pool.Pool -> BenchConfig -> String -> Int -> Int -> (QueueName -> IO a) -> IO a
withFifoQueue pool config suffix count numGroups action = do
  let queue = benchQueueName ("fifo_" <> Text.pack suffix)
  createBenchQueue pool queue
  runSession pool $ Pgmq.createFifoIndex queue
  seedQueueWithHeaders pool queue count numGroups Small
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

runReadGrouped :: Pool.Pool -> QueueName -> Int -> IO ()
runReadGrouped pool queue batchSize = do
  let req = Q.ReadGrouped {queueName = queue, visibilityTimeout = 30, qty = fromIntegral batchSize}
  msgs <- runSession pool $ Pgmq.readGrouped req
  deleteMessages pool queue msgs

runReadGroupedRR :: Pool.Pool -> QueueName -> Int -> IO ()
runReadGroupedRR pool queue batchSize = do
  let req = Q.ReadGrouped {queueName = queue, visibilityTimeout = 30, qty = fromIntegral batchSize}
  msgs <- runSession pool $ Pgmq.readGroupedRoundRobin req
  deleteMessages pool queue msgs

deleteMessages :: Pool.Pool -> QueueName -> V.Vector Message -> IO ()
deleteMessages pool queue msgs = do
  let msgIds = V.toList $ V.map (\(Message mid _ _ _ _ _ _) -> mid) msgs
  if null msgIds
    then pure ()
    else do
      _ <- runSession pool $ Pgmq.batchDeleteMessages Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
      pure ()
