module Bench.Throughput (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    runSession,
    seedQueue,
  )
import Control.Monad (forM_, replicateM_)
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
    "throughput"
    [ sendOnlyBenchmarks pool config,
      readOnlyBenchmarks pool config,
      fullCycleBenchmarks pool config,
      burstBenchmarks pool config
    ]

sendOnlyBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
sendOnlyBenchmarks pool config =
  bgroup
    "send-only"
    [ bench "100-msgs" $ nfIO $ withQueue pool config "send100" $ \q -> runSendMany pool q 100,
      bench "1000-msgs" $ nfIO $ withQueue pool config "send1000" $ \q -> runSendMany pool q 1000,
      bench "batch-1000" $ nfIO $ withQueue pool config "batch1000" $ \q -> runSendBatch pool q 1000
    ]

readOnlyBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
readOnlyBenchmarks pool config =
  bgroup
    "read-only"
    [ bench "pop-100" $ nfIO $ withSeededQueue pool config "pop100" config.messageCount $ \q -> runPopMany pool q 100,
      bench "pop-1000" $ nfIO $ withSeededQueue pool config "pop1000" config.messageCount $ \q -> runPopMany pool q 1000
    ]

fullCycleBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
fullCycleBenchmarks pool config =
  bgroup
    "full-cycle"
    [ bench "send-read-delete-100" $ nfIO $ withQueue pool config "cycle100" $ \q -> runFullCycle pool q 100,
      bench "send-read-delete-1000" $ nfIO $ withQueue pool config "cycle1000" $ \q -> runFullCycle pool q 1000
    ]

burstBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
burstBenchmarks pool config =
  bgroup
    "burst"
    [ bench "burst-100" $ nfIO $ withQueue pool config "burst100" $ \q -> runBurst pool q 100,
      bench "burst-1000" $ nfIO $ withQueue pool config "burst1000" $ \q -> runBurst pool q 1000
    ]

withQueue :: Pool.Pool -> BenchConfig -> String -> (QueueName -> IO a) -> IO a
withQueue pool config suffix action = do
  let queue = benchQueueName ("throughput_" <> Text.pack suffix)
  createBenchQueue pool queue
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

withSeededQueue :: Pool.Pool -> BenchConfig -> String -> Int -> (QueueName -> IO a) -> IO a
withSeededQueue pool config suffix count action = do
  let queue = benchQueueName ("throughput_" <> Text.pack suffix)
  createBenchQueue pool queue
  seedQueue pool queue count Small
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

runSendMany :: Pool.Pool -> QueueName -> Int -> IO ()
runSendMany pool queue count = do
  forM_ [1 .. count] $ \i -> do
    let msg = Q.SendMessage {queueName = queue, messageBody = MessageBody $ object ["id" .= (i :: Int)], delay = Nothing}
    _ <- runSession pool $ Pgmq.sendMessage msg
    pure ()

runSendBatch :: Pool.Pool -> QueueName -> Int -> IO ()
runSendBatch pool queue count = do
  let bodies = [MessageBody $ object ["id" .= i] | i <- [1 .. count]]
      msg = Q.BatchSendMessage {queueName = queue, messageBodies = bodies, delay = Nothing}
  _ <- runSession pool $ Pgmq.batchSendMessage msg
  pure ()

runPopMany :: Pool.Pool -> QueueName -> Int -> IO ()
runPopMany pool queue count = do
  let batchSize = min 100 count
      iterations = count `div` batchSize
  replicateM_ iterations $ do
    _ <- runSession pool $ Pgmq.pop Q.PopMessage {queueName = queue, qty = Just (fromIntegral batchSize)}
    pure ()

runFullCycle :: Pool.Pool -> QueueName -> Int -> IO ()
runFullCycle pool queue count = do
  let bodies = [MessageBody $ object ["id" .= i] | i <- [1 .. count]]
  _ <- runSession pool $ Pgmq.batchSendMessage Q.BatchSendMessage {queueName = queue, messageBodies = bodies, delay = Nothing}
  let batchSize = min 100 count
      iterations = (count + batchSize - 1) `div` batchSize
  replicateM_ iterations $ do
    let req = Q.ReadMessage {queueName = queue, delay = 30, batchSize = Just (fromIntegral batchSize), conditional = Nothing}
    msgs <- runSession pool $ Pgmq.readMessage req
    deleteMessages pool queue msgs

runBurst :: Pool.Pool -> QueueName -> Int -> IO ()
runBurst pool queue count = do
  let bodies = [MessageBody $ object ["id" .= i] | i <- [1 .. count]]
  _ <- runSession pool $ Pgmq.batchSendMessage Q.BatchSendMessage {queueName = queue, messageBodies = bodies, delay = Nothing}
  let batchSize = min 100 count
      iterations = (count + batchSize - 1) `div` batchSize
  replicateM_ iterations $ do
    _ <- runSession pool $ Pgmq.pop Q.PopMessage {queueName = queue, qty = Just (fromIntegral batchSize)}
    pure ()

deleteMessages :: Pool.Pool -> QueueName -> V.Vector Message -> IO ()
deleteMessages pool queue msgs = do
  let msgIds = V.toList $ V.map (\(Message mid _ _ _ _ _) -> mid) msgs
  if null msgIds
    then pure ()
    else do
      _ <- runSession pool $ Pgmq.batchDeleteMessages Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
      pure ()
