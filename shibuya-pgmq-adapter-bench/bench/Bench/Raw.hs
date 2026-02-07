-- | Raw pgmq-hasql vs effectful layer comparison benchmarks.
module Bench.Raw (benchmarks) where

import BenchConfig (BenchConfig (..), PayloadSize (..))
import BenchSetup
  ( benchQueueName,
    createBenchQueue,
    dropBenchQueue,
    purgeQueue,
    runSession,
    seedQueue,
  )
import Data.Aeson (object, (.=))
import Data.Text qualified as Text
import Data.Vector qualified as V
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Pgmq.Effectful (Pgmq, PgmqError, runPgmq)
import Pgmq.Effectful qualified as Eff
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Types (Message (..), MessageBody (..), QueueName)
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)

benchmarks :: Pool.Pool -> BenchConfig -> Benchmark
benchmarks pool config =
  bgroup
    "raw-vs-effectful"
    [ sendComparison pool config,
      readComparison pool config,
      ackComparison pool config
    ]

sendComparison :: Pool.Pool -> BenchConfig -> Benchmark
sendComparison pool config =
  bgroup
    "send"
    [ bgroup
        "single"
        [ bench "raw-hasql" $ nfIO $ withQueue pool config "raw" $ rawSendSingle pool,
          bench "effectful" $ nfIO $ withQueue pool config "eff" $ effSendSingle pool
        ],
      bgroup
        "batch-100"
        [ bench "raw-hasql" $ nfIO $ withQueue pool config "rawb" $ \q -> rawSendBatch pool q 100,
          bench "effectful" $ nfIO $ withQueue pool config "effb" $ \q -> effSendBatch pool q 100
        ]
    ]

readComparison :: Pool.Pool -> BenchConfig -> Benchmark
readComparison pool config =
  bgroup
    "read"
    [ bgroup
        "batch-10"
        [ bench "raw-hasql" $ nfIO $ withSeededQueue pool config "rawr10" 10000 $ \q -> rawReadBatch pool q 10,
          bench "effectful" $ nfIO $ withSeededQueue pool config "effr10" 10000 $ \q -> effReadBatch pool q 10
        ]
    ]

ackComparison :: Pool.Pool -> BenchConfig -> Benchmark
ackComparison pool config =
  bgroup
    "ack"
    [ bgroup
        "delete"
        [ bench "raw-hasql" $ nfIO $ withSeededQueue pool config "rawdel" 10000 $ rawDelete pool,
          bench "effectful" $ nfIO $ withSeededQueue pool config "effdel" 10000 $ effDelete pool
        ]
    ]

withQueue :: Pool.Pool -> BenchConfig -> String -> (QueueName -> IO a) -> IO a
withQueue pool config suffix action = do
  let queue = benchQueueName ("raw_" <> Text.pack suffix)
  createBenchQueue pool queue
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

withSeededQueue :: Pool.Pool -> BenchConfig -> String -> Int -> (QueueName -> IO a) -> IO a
withSeededQueue pool config suffix count action = do
  let queue = benchQueueName ("raw_" <> Text.pack suffix)
  createBenchQueue pool queue
  seedQueue pool queue count Small
  result <- action queue
  purgeQueue pool queue
  if config.skipCleanup then pure () else dropBenchQueue pool queue
  pure result

-- Raw hasql operations

rawSendSingle :: Pool.Pool -> QueueName -> IO ()
rawSendSingle pool queue = do
  let msg = Q.SendMessage {queueName = queue, messageBody = MessageBody $ object ["id" .= (1 :: Int)], delay = Nothing}
  _ <- runSession pool $ Pgmq.sendMessage msg
  pure ()

rawSendBatch :: Pool.Pool -> QueueName -> Int -> IO ()
rawSendBatch pool queue n = do
  let bodies = [MessageBody $ object ["id" .= i] | i <- [1 .. n]]
  _ <- runSession pool $ Pgmq.batchSendMessage Q.BatchSendMessage {queueName = queue, messageBodies = bodies, delay = Nothing}
  pure ()

rawReadBatch :: Pool.Pool -> QueueName -> Int -> IO ()
rawReadBatch pool queue n = do
  let req = Q.ReadMessage {queueName = queue, delay = 30, batchSize = Just (fromIntegral n), conditional = Nothing}
  msgs <- runSession pool $ Pgmq.readMessage req
  deleteMessages pool queue msgs

rawDelete :: Pool.Pool -> QueueName -> IO ()
rawDelete pool queue = do
  let readReq = Q.ReadMessage {queueName = queue, delay = 300, batchSize = Just 1, conditional = Nothing}
  msgs <- runSession pool $ Pgmq.readMessage readReq
  case V.toList msgs of
    (Message msgId _ _ _ _ _ _ : _) -> do
      _ <- runSession pool $ Pgmq.deleteMessage Q.MessageQuery {queueName = queue, messageId = msgId}
      pure ()
    [] -> pure ()

-- Effectful layer operations

runEffectful :: Pool.Pool -> Eff '[Pgmq, Error PgmqError, IOE] a -> IO ()
runEffectful pool action = do
  result <- runEff . runErrorNoCallStack @PgmqError . runPgmq pool $ action
  case result of
    Left _ -> pure ()
    Right _ -> pure ()

effSendSingle :: Pool.Pool -> QueueName -> IO ()
effSendSingle pool queue = runEffectful pool $ do
  let msg = Q.SendMessage {queueName = queue, messageBody = MessageBody $ object ["id" .= (1 :: Int)], delay = Nothing}
  _ <- Eff.sendMessage msg
  pure ()

effSendBatch :: Pool.Pool -> QueueName -> Int -> IO ()
effSendBatch pool queue n = runEffectful pool $ do
  let bodies = [MessageBody $ object ["id" .= i] | i <- [1 .. n]]
  _ <- Eff.batchSendMessage Q.BatchSendMessage {queueName = queue, messageBodies = bodies, delay = Nothing}
  pure ()

effReadBatch :: Pool.Pool -> QueueName -> Int -> IO ()
effReadBatch pool queue n = do
  result <- runEff . runErrorNoCallStack @PgmqError . runPgmq pool $ do
    let req = Q.ReadMessage {queueName = queue, delay = 30, batchSize = Just (fromIntegral n), conditional = Nothing}
    Eff.readMessage req
  case result of
    Left _ -> pure ()
    Right msgs -> deleteMessages pool queue msgs

effDelete :: Pool.Pool -> QueueName -> IO ()
effDelete pool queue = do
  let readReq = Q.ReadMessage {queueName = queue, delay = 300, batchSize = Just 1, conditional = Nothing}
  msgs <- runSession pool $ Pgmq.readMessage readReq
  case V.toList msgs of
    (Message msgId _ _ _ _ _ _ : _) -> runEffectful pool $ do
      _ <- Eff.deleteMessage Q.MessageQuery {queueName = queue, messageId = msgId}
      pure ()
    [] -> pure ()

deleteMessages :: Pool.Pool -> QueueName -> V.Vector Message -> IO ()
deleteMessages pool queue msgs = do
  let msgIds = V.toList $ V.map (\(Message mid _ _ _ _ _ _) -> mid) msgs
  if null msgIds
    then pure ()
    else do
      _ <- runSession pool $ Pgmq.batchDeleteMessages Q.BatchMessageQuery {queueName = queue, messageIds = msgIds}
      pure ()
