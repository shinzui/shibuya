module Bench.Concurrent (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    runSession,
    seedQueue,
  )
import Control.Concurrent.Async (forConcurrently_)
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
    "concurrent"
    [ readerBenchmarks pool config,
      writerBenchmarks pool config,
      mixedBenchmarks pool config,
      scalingBenchmarks pool config
    ]

readerBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
readerBenchmarks pool config =
  bgroup
    "readers"
    [ bench "2-readers" $ nfIO $ withSeededQueue pool config "r2" 10000 $ \q -> runConcurrentReaders pool q 2 50,
      bench "4-readers" $ nfIO $ withSeededQueue pool config "r4" 10000 $ \q -> runConcurrentReaders pool q 4 50,
      bench "8-readers" $ nfIO $ withSeededQueue pool config "r8" 10000 $ \q -> runConcurrentReaders pool q 8 50
    ]

writerBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
writerBenchmarks pool config =
  bgroup
    "writers"
    [ bench "2-writers" $ nfIO $ withQueue pool config "w2" $ \q -> runConcurrentWriters pool q 2 100,
      bench "4-writers" $ nfIO $ withQueue pool config "w4" $ \q -> runConcurrentWriters pool q 4 100,
      bench "8-writers" $ nfIO $ withQueue pool config "w8" $ \q -> runConcurrentWriters pool q 8 100
    ]

mixedBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
mixedBenchmarks pool config =
  bgroup
    "mixed"
    [ bench "2r-2w" $ nfIO $ withSeededQueue pool config "m2" 10000 $ \q -> runMixed pool q 2 2 50,
      bench "4r-4w" $ nfIO $ withSeededQueue pool config "m4" 10000 $ \q -> runMixed pool q 4 4 50
    ]

scalingBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
scalingBenchmarks pool config =
  bgroup
    "scaling"
    [ bench "1-worker" $ nfIO $ withSeededQueue pool config "s1" 50000 $ \q -> runScaling pool q 1 1000,
      bench "2-workers" $ nfIO $ withSeededQueue pool config "s2" 50000 $ \q -> runScaling pool q 2 1000,
      bench "4-workers" $ nfIO $ withSeededQueue pool config "s4" 50000 $ \q -> runScaling pool q 4 1000
    ]

withQueue :: Pool.Pool -> BenchConfig -> String -> (QueueName -> IO a) -> IO a
withQueue pool config suffix action = do
  let queue = benchQueueName ("concurrent_" <> Text.pack suffix)
  createBenchQueue pool queue
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

withSeededQueue :: Pool.Pool -> BenchConfig -> String -> Int -> (QueueName -> IO a) -> IO a
withSeededQueue pool config suffix count action = do
  let queue = benchQueueName ("concurrent_" <> Text.pack suffix)
  createBenchQueue pool queue
  seedQueue pool queue count Small
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

runConcurrentReaders :: Pool.Pool -> QueueName -> Int -> Int -> IO ()
runConcurrentReaders pool queue numReaders batchSize = do
  forConcurrently_ [1 .. numReaders] $ \_ -> do
    replicateM_ 10 $ do
      let req = Q.ReadMessage {queueName = queue, delay = 30, batchSize = Just (fromIntegral batchSize), conditional = Nothing}
      msgs <- runSession pool $ Pgmq.readMessage req
      deleteMessages pool queue msgs

runConcurrentWriters :: Pool.Pool -> QueueName -> Int -> Int -> IO ()
runConcurrentWriters pool queue numWriters msgsPerWriter = do
  forConcurrently_ [1 .. numWriters] $ \writerId -> do
    forM_ [1 .. msgsPerWriter] $ \i -> do
      let msg = Q.SendMessage {queueName = queue, messageBody = MessageBody $ object ["writer" .= writerId, "id" .= (i :: Int)], delay = Nothing}
      _ <- runSession pool $ Pgmq.sendMessage msg
      pure ()

runMixed :: Pool.Pool -> QueueName -> Int -> Int -> Int -> IO ()
runMixed pool queue numReaders numWriters batchSize = do
  let readers = [1 .. numReaders]
      writers = [(numReaders + 1) .. (numReaders + numWriters)]
  forConcurrently_ (readers ++ writers) $ \workerId -> do
    if workerId <= numReaders
      then replicateM_ 10 $ do
        let req = Q.ReadMessage {queueName = queue, delay = 30, batchSize = Just (fromIntegral batchSize), conditional = Nothing}
        msgs <- runSession pool $ Pgmq.readMessage req
        deleteMessages pool queue msgs
      else forM_ [1 .. 50 :: Int] $ \i -> do
        let msg = Q.SendMessage {queueName = queue, messageBody = MessageBody $ object ["writer" .= workerId, "id" .= i], delay = Nothing}
        _ <- runSession pool $ Pgmq.sendMessage msg
        pure ()

runScaling :: Pool.Pool -> QueueName -> Int -> Int -> IO ()
runScaling pool queue numWorkers totalMsgs = do
  let msgsPerWorker = totalMsgs `div` numWorkers
  forConcurrently_ [1 .. numWorkers] $ \_ -> do
    replicateM_ (msgsPerWorker `div` 10) $ do
      _ <- runSession pool $ Pgmq.pop Q.PopMessage {queueName = queue, qty = Just 10}
      pure ()

deleteMessages :: Pool.Pool -> QueueName -> V.Vector Message -> IO ()
deleteMessages pool queue msgs = do
  let msgIds = V.toList $ V.map (\(Message mid _ _ _ _ _ _) -> mid) msgs
  if null msgIds
    then pure ()
    else do
      _ <- runSession pool $ Pgmq.batchDeleteMessages Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
      pure ()
