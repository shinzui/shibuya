module Bench.Read (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    runSession,
    seedQueue,
  )
import Data.Text qualified as Text
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types (Message (..), MessageId, QueueName)
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)

benchmarks :: Pool.Pool -> BenchConfig -> Benchmark
benchmarks pool config =
  bgroup
    "read"
    [ singleReadBenchmarks pool config,
      batchReadBenchmarks pool config,
      pollBenchmarks pool config
    ]

singleReadBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
singleReadBenchmarks pool config =
  bgroup
    "single"
    [bench "read-1" $ nfIO $ withSeededQueue pool config "single" 1000 $ runReadSingle pool]

batchReadBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
batchReadBenchmarks pool config =
  bgroup
    "batch"
    [ bench "read-10" $ nfIO $ withSeededQueue pool config "batch10" 10000 $ \q -> runReadBatch pool q 10,
      bench "read-50" $ nfIO $ withSeededQueue pool config "batch50" 10000 $ \q -> runReadBatch pool q 50,
      bench "read-100" $ nfIO $ withSeededQueue pool config "batch100" 10000 $ \q -> runReadBatch pool q 100
    ]

pollBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
pollBenchmarks pool config =
  bgroup
    "poll"
    [ bench "poll-immediate" $ nfIO $ withSeededQueue pool config "poll1" 1000 $ \q -> runReadWithPoll pool q 1 100,
      bench "poll-batch-10" $ nfIO $ withSeededQueue pool config "poll10" 1000 $ \q -> runReadWithPoll pool q 10 100
    ]

withSeededQueue :: Pool.Pool -> BenchConfig -> String -> Int -> (QueueName -> IO a) -> IO a
withSeededQueue pool config suffix count action = do
  let queue = benchQueueName ("read_" <> Text.pack suffix)
  createBenchQueue pool queue
  seedQueue pool queue count Small
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

runReadSingle :: Pool.Pool -> QueueName -> IO ()
runReadSingle pool queue = do
  let req = Q.ReadMessage {queueName = queue, delay = 30, batchSize = Just 1, conditional = Nothing}
  msgs <- runSession pool $ Pgmq.readMessage req
  deleteMessages pool queue msgs

runReadBatch :: Pool.Pool -> QueueName -> Int -> IO ()
runReadBatch pool queue n = do
  let req = Q.ReadMessage {queueName = queue, delay = 30, batchSize = Just (fromIntegral n), conditional = Nothing}
  msgs <- runSession pool $ Pgmq.readMessage req
  deleteMessages pool queue msgs

runReadWithPoll :: Pool.Pool -> QueueName -> Int -> Int -> IO ()
runReadWithPoll pool queue batchSize pollMs = do
  let req =
        Q.ReadWithPollMessage
          { queueName = queue,
            delay = 30,
            batchSize = Just (fromIntegral batchSize),
            maxPollSeconds = 1,
            pollIntervalMs = fromIntegral pollMs,
            conditional = Nothing
          }
  msgs <- runSession pool $ Pgmq.readWithPoll req
  deleteMessages pool queue msgs

deleteMessages :: Pool.Pool -> QueueName -> V.Vector Message -> IO ()
deleteMessages pool queue msgs = do
  let msgIds = V.toList $ V.map (\(Message mid _ _ _ _ _) -> mid) msgs
  if null msgIds
    then pure ()
    else do
      let req = Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
      _ <- runSession pool $ Pgmq.batchDeleteMessages req
      pure ()
