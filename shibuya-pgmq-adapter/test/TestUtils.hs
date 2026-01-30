-- | Utility functions for integration tests.
module TestUtils
  ( -- * Effectful helpers
    runWithPool,

    -- * Queue helpers
    getQueueLength,
    getArchiveLength,
    sendTestMessage,
    sendTestMessageWithHeaders,

    -- * Assertions
    shouldEventuallyBe,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson (Value)
import Data.Int (Int64)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Pgmq.Effectful (Pgmq, PgmqError, runPgmq)
import Pgmq.Effectful qualified as Pgmq
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types (SendMessage (..), SendMessageWithHeaders (..))
import Pgmq.Types (MessageBody (..), MessageHeaders (..), QueueName)
import Test.Hspec (Expectation, expectationFailure)
import TmpPostgres (runPgmqSession)

-- | Run an Eff action with Pgmq effect against a pool.
-- This handles the Error PgmqError effect and throws on errors.
runWithPool :: Pool.Pool -> Eff '[Pgmq, Error PgmqError, IOE] a -> IO a
runWithPool pool action = do
  result <- runEff $ runErrorNoCallStack $ runPgmq pool action
  case result of
    Left err -> error $ "Pgmq error: " <> show err
    Right a -> pure a

-- | Get the number of visible messages in a queue.
getQueueLength :: Pool.Pool -> QueueName -> IO Int64
getQueueLength pool queueName = do
  metrics <- runPgmqSession pool $ Sessions.queueMetrics queueName
  pure metrics.queueLength

-- | Get the number of archived messages in a queue.
-- Note: This requires querying the archive table directly.
-- For now, we return 0 as archive length is complex to query.
getArchiveLength :: Pool.Pool -> QueueName -> IO Int64
getArchiveLength _pool _queueName = pure 0 -- TODO: implement archive length query

-- | Send a test message to a queue.
sendTestMessage :: Pool.Pool -> QueueName -> Value -> IO ()
sendTestMessage pool queueName payload =
  runPgmqSession pool $ do
    _ <-
      Sessions.sendMessage $
        SendMessage
          { queueName = queueName,
            messageBody = MessageBody payload,
            delay = Nothing
          }
    pure ()

-- | Send a test message with custom headers (for FIFO testing).
sendTestMessageWithHeaders :: Pool.Pool -> QueueName -> Value -> Value -> IO ()
sendTestMessageWithHeaders pool queueName payload headers =
  runPgmqSession pool $ do
    _ <-
      Sessions.sendMessageWithHeaders $
        SendMessageWithHeaders
          { queueName = queueName,
            messageBody = MessageBody payload,
            messageHeaders = MessageHeaders headers,
            delay = Nothing
          }
    pure ()

-- | Wait for a condition to become true, with timeout.
-- Useful for testing visibility timeout expiration.
shouldEventuallyBe :: (Eq a, Show a) => IO a -> a -> Int -> Expectation
shouldEventuallyBe action expected maxWaitMs = go 0
  where
    go waited
      | waited >= maxWaitMs = do
          actual <- action
          if actual == expected
            then pure ()
            else expectationFailure $ "Timed out waiting for condition. Expected: " <> show expected <> ", got: " <> show actual
      | otherwise = do
          actual <- action
          if actual == expected
            then pure ()
            else do
              threadDelay 100000 -- 100ms
              go (waited + 100)
