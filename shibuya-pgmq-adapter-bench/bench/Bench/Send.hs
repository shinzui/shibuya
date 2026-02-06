module Bench.Send (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    generatePayload,
    purgeQueue,
    runSession,
  )
import Data.Aeson (object, (.=))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Hasql.Pool qualified as Pool
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types (MessageBody (..), MessageHeaders (..), QueueName)
import Test.Tasty.Bench
  ( Benchmark,
    bench,
    bgroup,
    nfIO,
  )

benchmarks :: Pool.Pool -> BenchConfig -> Benchmark
benchmarks pool config =
  bgroup
    "send"
    [ singleBenchmarks pool config,
      batchBenchmarks pool config,
      headerBenchmarks pool config,
      delayedBenchmarks pool config,
      payloadBenchmarks pool config
    ]

-- | Single message send benchmarks
singleBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
singleBenchmarks pool config =
  bgroup "single" [bench "send" $ nfIO $ withQueue pool config "single" $ runSendSingle pool]

-- | Batch send benchmarks
batchBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
batchBenchmarks pool config =
  bgroup
    "batch"
    [ bench "batch-10" $ nfIO $ withQueue pool config "batch10" $ \q -> runSendBatch pool q 10,
      bench "batch-100" $ nfIO $ withQueue pool config "batch100" $ \q -> runSendBatch pool q 100,
      bench "batch-1000" $ nfIO $ withQueue pool config "batch1000" $ \q -> runSendBatch pool q 1000
    ]

-- | Send with headers benchmarks
headerBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
headerBenchmarks pool config =
  bgroup
    "headers"
    [ bench "with-headers" $ nfIO $ withQueue pool config "hdr" $ runSendWithHeaders pool,
      bench "with-fifo-group" $ nfIO $ withQueue pool config "fifo" $ runSendWithFifoGroup pool
    ]

-- | Delayed send benchmarks
delayedBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
delayedBenchmarks pool config =
  bgroup
    "delayed"
    [ bench "delay-5s" $ nfIO $ withQueue pool config "delay5" $ \q -> runSendDelayed pool q 5,
      bench "delay-30s" $ nfIO $ withQueue pool config "delay30" $ \q -> runSendDelayed pool q 30
    ]

-- | Payload size benchmarks
payloadBenchmarks :: Pool.Pool -> BenchConfig -> Benchmark
payloadBenchmarks pool config =
  bgroup
    "payload"
    [ bench "small-100b" $ nfIO $ withQueue pool config "small" $ \q -> runSendPayload pool q Small,
      bench "medium-10kb" $ nfIO $ withQueue pool config "medium" $ \q -> runSendPayload pool q Medium,
      bench "large-100kb" $ nfIO $ withQueue pool config "large" $ \q -> runSendPayload pool q Large
    ]

-- | Run action with a fresh queue, cleaning up after
withQueue :: Pool.Pool -> BenchConfig -> String -> (QueueName -> IO a) -> IO a
withQueue pool config suffix action = do
  let queue = benchQueueName ("send_" <> Text.pack suffix)
  createBenchQueue pool queue
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup
    then pure ()
    else dropBenchQueue pool queue
  pure result

-- | Send a single message
runSendSingle :: Pool.Pool -> QueueName -> IO ()
runSendSingle pool queue = do
  let msg =
        Q.SendMessage
          { queueName = queue,
            messageBody = MessageBody $ object ["id" .= (1 :: Int)],
            delay = Nothing
          }
  _ <- runSession pool $ Pgmq.sendMessage msg
  pure ()

-- | Send a batch of messages
runSendBatch :: Pool.Pool -> QueueName -> Int -> IO ()
runSendBatch pool queue n = do
  let bodies = [MessageBody $ object ["id" .= i] | i <- [1 .. n]]
      msg =
        Q.BatchSendMessage
          { queueName = queue,
            messageBodies = bodies,
            delay = Nothing
          }
  _ <- runSession pool $ Pgmq.batchSendMessage msg
  pure ()

-- | Send with headers
runSendWithHeaders :: Pool.Pool -> QueueName -> IO ()
runSendWithHeaders pool queue = do
  let msg =
        Q.SendMessageWithHeaders
          { queueName = queue,
            messageBody = MessageBody $ object ["id" .= (1 :: Int)],
            messageHeaders = MessageHeaders $ object ["type" .= ("test" :: String)],
            delay = Nothing
          }
  _ <- runSession pool $ Pgmq.sendMessageWithHeaders msg
  pure ()

-- | Send with FIFO group header
runSendWithFifoGroup :: Pool.Pool -> QueueName -> IO ()
runSendWithFifoGroup pool queue = do
  let msg =
        Q.SendMessageWithHeaders
          { queueName = queue,
            messageBody = MessageBody $ object ["id" .= (1 :: Int)],
            messageHeaders = MessageHeaders $ object ["x-pgmq-group" .= ("group-1" :: String)],
            delay = Nothing
          }
  _ <- runSession pool $ Pgmq.sendMessageWithHeaders msg
  pure ()

-- | Send with delay
runSendDelayed :: Pool.Pool -> QueueName -> Int -> IO ()
runSendDelayed pool queue delaySec = do
  let msg =
        Q.SendMessage
          { queueName = queue,
            messageBody = MessageBody $ object ["id" .= (1 :: Int)],
            delay = Just (fromIntegral delaySec)
          }
  _ <- runSession pool $ Pgmq.sendMessage msg
  pure ()

-- | Send with specific payload size
runSendPayload :: Pool.Pool -> QueueName -> PayloadSize -> IO ()
runSendPayload pool queue size = do
  let payload = generatePayload size 1
      msg =
        Q.SendMessage
          { queueName = queue,
            messageBody = MessageBody payload,
            delay = Nothing
          }
  _ <- runSession pool $ Pgmq.sendMessage msg
  pure ()
