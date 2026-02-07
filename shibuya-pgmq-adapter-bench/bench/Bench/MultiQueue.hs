module Bench.MultiQueue (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    runSession,
    seedQueue,
    uniqueQueueName,
  )
import Control.Monad (forM, forM_)
import Data.Aeson (object, (.=))
import Data.Text qualified as Text
import Data.Vector qualified as V
import Hasql.Pool qualified as Pool
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types (Message (..), MessageBody (..), QueueName)
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)

benchmarks :: Pool.Pool -> BenchConfig -> Benchmark
benchmarks pool config =
  bgroup
    "multi"
    [ sendRoundRobinBenchmarks pool config,
      readAllBenchmarks pool config,
      queueLifecycleBenchmarks pool config,
      metricsBenchmarks pool config
    ]

sendRoundRobinBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
sendRoundRobinBenchmarks pool config =
  bgroup
    "send-round-robin"
    [ bench "100-msgs-4-queues" $ nfIO $ withMultiQueue pool config 4 "rr" $ \qs -> runSendRoundRobin pool qs 100,
      bench "1000-msgs-4-queues" $ nfIO $ withMultiQueue pool config 4 "rr" $ \qs -> runSendRoundRobin pool qs 1000
    ]

readAllBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
readAllBenchmarks pool config =
  bgroup
    "read-all"
    [bench "read-all-queues" $ nfIO $ withSeededMultiQueue pool config 4 "read" 1000 $ \qs -> runReadAll pool qs 10]

queueLifecycleBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
queueLifecycleBenchmarks pool _config =
  bgroup
    "lifecycle"
    [ bench "create-drop-cycle" $ nfIO $ runCreateDropCycle pool
    ]

metricsBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
metricsBenchmarks pool config =
  bgroup
    "metrics"
    [ bench "single-queue" $ nfIO $ withSeededMultiQueue pool config 1 "metrics" 100 $ \qs -> runSingleMetrics pool (head qs),
      bench "all-queues" $ nfIO $ withSeededMultiQueue pool config 4 "metrics" 100 $ \_ -> runAllMetrics pool
    ]

withMultiQueue :: Pool.Pool -> BenchConfig -> Int -> String -> ([QueueName] -> IO a) -> IO a
withMultiQueue pool config count prefix action = do
  queues <- forM [1 .. count] $ \i -> do
    let queue = benchQueueName (Text.pack prefix <> "_" <> Text.pack (show i))
    createBenchQueue pool queue
    pure queue
  result <- action queues
  forM_ queues $ \queue -> do
    purgeQueue pool queue
    if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

withSeededMultiQueue :: Pool.Pool -> BenchConfig -> Int -> String -> Int -> ([QueueName] -> IO a) -> IO a
withSeededMultiQueue pool config count prefix msgCount action = do
  queues <- forM [1 .. count] $ \i -> do
    let queue = benchQueueName (Text.pack prefix <> "_" <> Text.pack (show i))
    createBenchQueue pool queue
    seedQueue pool queue msgCount Small
    pure queue
  result <- action queues
  forM_ queues $ \queue -> do
    purgeQueue pool queue
    if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

runSendRoundRobin :: Pool.Pool -> [QueueName] -> Int -> IO ()
runSendRoundRobin pool queues msgCount = do
  let queueList = cycle queues
      pairs = zip queueList [1 .. msgCount]
  forM_ pairs $ \(queue, i) -> do
    let msg = Q.SendMessage {queueName = queue, messageBody = MessageBody $ object ["id" .= (i :: Int)], delay = Nothing}
    _ <- runSession pool $ Pgmq.sendMessage msg
    pure ()

runReadAll :: Pool.Pool -> [QueueName] -> Int -> IO ()
runReadAll pool queues batchSize = do
  forM_ queues $ \queue -> do
    let req = Q.ReadMessage {queueName = queue, delay = 30, batchSize = Just (fromIntegral batchSize), conditional = Nothing}
    msgs <- runSession pool $ Pgmq.readMessage req
    let msgIds = V.toList $ V.map (\(Message mid _ _ _ _ _ _) -> mid) msgs
    if null msgIds
      then pure ()
      else do
        _ <- runSession pool $ Pgmq.batchDeleteMessages Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
        pure ()

runCreateDropCycle :: Pool.Pool -> IO ()
runCreateDropCycle pool = do
  queue <- uniqueQueueName "cycle"
  createBenchQueue pool queue
  let msg = Q.SendMessage {queueName = queue, messageBody = MessageBody $ object ["test" .= True], delay = Nothing}
  _ <- runSession pool $ Pgmq.sendMessage msg
  dropBenchQueue pool queue

runSingleMetrics :: Pool.Pool -> QueueName -> IO ()
runSingleMetrics pool queue = do
  _ <- runSession pool $ Pgmq.queueMetrics queue
  pure ()

runAllMetrics :: Pool.Pool -> IO ()
runAllMetrics pool = do
  _ <- runSession pool Pgmq.allQueueMetrics
  pure ()
