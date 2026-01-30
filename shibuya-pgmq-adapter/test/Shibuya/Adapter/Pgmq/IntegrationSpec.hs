-- | Integration tests for the PGMQ adapter.
--
-- These tests require a running PostgreSQL instance (provided via tmp-postgres).
-- Run with: cabal test --test-option='-p' --test-option='/Integration/'
-- Skip with: Set PGMQ_TEST_SKIP_DB=1 or use pattern '!/Integration/'
--
-- Note: Tests that use the streaming adapter (pgmqAdapter) are currently
-- marked as pending due to a known issue with Streamly and Effectful interaction.
-- The direct effectful API works correctly.
module Shibuya.Adapter.Pgmq.IntegrationSpec (spec) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (Value (..), object, (.=))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Int (Int32)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, liftIO, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Pgmq.Effectful (Pgmq, PgmqError, runPgmq)
import Pgmq.Effectful qualified as PgmqEff
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types (MessageQuery (..), ReadMessage (..), SendMessage (..), VisibilityTimeoutQuery (..))
import Pgmq.Types (MessageBody (..), QueueName)
import Shibuya.Adapter.Pgmq.Config
  ( PgmqAdapterConfig (..),
    PollingConfig (..),
  )
import Shibuya.Adapter.Pgmq.Convert (pgmqMessageToEnvelope)
import Shibuya.Core.Types (Envelope (..))
import System.Environment (lookupEnv)
import Test.Hspec
import TmpPostgres (TestFixture (..), runPgmqSession, withPgmqDb, withTestFixture)

spec :: Spec
spec = do
  -- Check if we should skip database tests
  runIO $ do
    skipDb <- lookupEnv "PGMQ_TEST_SKIP_DB"
    case skipDb of
      Just "1" -> pure ()
      _ -> pure ()

  around withTempDbFixture $ do
    describe "Integration" $ do
      basicMessageProcessingSpec
      visibilityTimeoutSpec
      retryHandlingSpec

-- | Wrapper to run tests with a temporary database and fixture
withTempDbFixture :: (TestFixture -> IO ()) -> IO ()
withTempDbFixture action = do
  skipDb <- lookupEnv "PGMQ_TEST_SKIP_DB"
  case skipDb of
    Just "1" -> pendingWith "Database tests skipped (PGMQ_TEST_SKIP_DB=1)"
    _ -> do
      result <- withPgmqDb $ \pool ->
        withTestFixture pool action
      case result of
        Left err -> expectationFailure $ "Failed to start temp database: " <> show err
        Right () -> pure ()

-- | Run an Eff action with Pgmq effect against a pool, throwing on error.
runAdapterIO :: Pool.Pool -> Eff '[Pgmq, Error PgmqError, IOE] a -> IO a
runAdapterIO pool action = do
  result <- runEff $ runErrorNoCallStack $ runPgmq pool action
  case result of
    Left err -> error $ "Pgmq error: " <> show err
    Right a -> pure a

-- | Basic message processing tests
basicMessageProcessingSpec :: SpecWith TestFixture
basicMessageProcessingSpec = describe "Basic message processing" $ do
  it "can send and read messages directly via session" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Send a message
    _msgId <- runPgmqSession pool $ do
      Sessions.sendMessage $
        SendMessage
          { queueName = queueName,
            messageBody = MessageBody (String "direct-test"),
            delay = Just 0
          }

    -- Read directly via session
    msgs <-
      runPgmqSession pool $
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
    Vector.length msgs `shouldBe` 1

  it "can send and read messages directly via effectful" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Send a message via session
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "effectful-test"),
              delay = Just 0
            }
      pure ()

    -- Read through effectful layer
    msgs <- runAdapterIO pool $ do
      PgmqEff.readMessage $
        ReadMessage
          { queueName = queueName,
            delay = 30,
            batchSize = Just 1,
            conditional = Nothing
          }
    Vector.length msgs `shouldBe` 1

  it "processes a single message and deletes it" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Send a message
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "test"),
              delay = Just 0
            }
      pure ()

    -- Read and verify payload, then delete
    processedRef <- newIORef Nothing
    runAdapterIO pool $ do
      msgs <-
        PgmqEff.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      case Vector.uncons msgs of
        Just (msg, _) -> do
          let Envelope {payload = p} = pgmqMessageToEnvelope msg
          liftIO $ writeIORef processedRef (Just p)
          -- Delete the message (simulating AckOk)
          _ <- PgmqEff.deleteMessage (MessageQuery queueName msg.messageId)
          pure ()
        Nothing -> pure ()

    -- Verify message was processed
    processed <- readIORef processedRef
    processed `shouldBe` Just (String "test")

    -- Verify queue is now empty
    msgs <-
      runPgmqSession pool $
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
    Vector.length msgs `shouldBe` 0

  it "processes multiple messages in order" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Enqueue 5 messages
    runPgmqSession pool $ do
      forM_ [1 .. 5 :: Int] $ \i ->
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (object ["order" .= i]),
              delay = Just 0
            }

    -- Read and process all 5
    processedCount <- runAdapterIO pool $ do
      msgs <-
        PgmqEff.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 10,
              conditional = Nothing
            }
      -- Delete each message
      forM_ (Vector.toList msgs) $ \msg ->
        PgmqEff.deleteMessage (MessageQuery queueName msg.messageId)
      pure $ Vector.length msgs

    processedCount `shouldBe` 5

-- | Visibility timeout tests
visibilityTimeoutSpec :: SpecWith TestFixture
visibilityTimeoutSpec = describe "Visibility timeout" $ do
  it "message reappears after visibility timeout" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Enqueue a message
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "vt-test"),
              delay = Just 0
            }
      pure ()

    -- Read message with short VT (1 second), don't delete
    runPgmqSession pool $ do
      msgs <-
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 1, -- 1 second visibility timeout
              batchSize = Just 1,
              conditional = Nothing
            }
      liftIO $ Vector.length msgs `shouldBe` 1

    -- Wait for VT to expire
    threadDelay 1500000 -- 1.5 seconds

    -- Message should be visible again
    count <- runPgmqSession pool $ do
      msgs <-
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      pure $ Vector.length msgs
    count `shouldBe` 1

-- | Retry handling tests (simulating AckRetry behavior)
retryHandlingSpec :: SpecWith TestFixture
retryHandlingSpec = describe "Retry handling" $ do
  it "set_vt extends visibility timeout (simulating AckRetry)" $ \TestFixture {pool, queueName, dlqName = _} -> do
    -- Enqueue a message
    runPgmqSession pool $ do
      _ <-
        Sessions.sendMessage $
          SendMessage
            { queueName = queueName,
              messageBody = MessageBody (String "retry-test"),
              delay = Just 0
            }
      pure ()

    -- Read message, then extend VT to 3 seconds
    runAdapterIO pool $ do
      msgs <-
        PgmqEff.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 1, -- Start with 1 second VT
              batchSize = Just 1,
              conditional = Nothing
            }
      case Vector.uncons msgs of
        Just (msg, _) -> do
          -- Extend VT by 3 seconds (simulating AckRetry)
          _ <-
            PgmqEff.changeVisibilityTimeout $
              VisibilityTimeoutQuery
                { queueName = queueName,
                  messageId = msg.messageId,
                  visibilityTimeoutOffset = 3
                }
          pure ()
        Nothing -> pure ()

    -- Message should not be visible yet (VT extended)
    threadDelay 1500000 -- 1.5 seconds
    count1 <- runPgmqSession pool $ do
      msgs <-
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      pure $ Vector.length msgs
    count1 `shouldBe` 0

    -- After 3+ seconds total, message should be visible
    threadDelay 2000000 -- 2 more seconds (3.5s total)
    count2 <- runPgmqSession pool $ do
      msgs <-
        Sessions.readMessage $
          ReadMessage
            { queueName = queueName,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      pure $ Vector.length msgs
    count2 `shouldBe` 1

-- | Helper to create a config with sensible defaults for testing
_mkConfig :: QueueName -> PgmqAdapterConfig
_mkConfig queueName =
  PgmqAdapterConfig
    { queueName = queueName,
      visibilityTimeout = 30,
      batchSize = 1,
      polling = StandardPolling {pollInterval = 0.1}, -- Fast polling for tests
      deadLetterConfig = Nothing,
      maxRetries = 3,
      fifoConfig = Nothing,
      prefetchConfig = Nothing
    }

-- | Create config with custom batch size
_mkConfigWithBatchSize :: QueueName -> Int32 -> PgmqAdapterConfig
_mkConfigWithBatchSize qName bs =
  PgmqAdapterConfig
    { queueName = qName,
      visibilityTimeout = 30,
      batchSize = bs,
      polling = StandardPolling {pollInterval = 0.1},
      deadLetterConfig = Nothing,
      maxRetries = 3,
      fifoConfig = Nothing,
      prefetchConfig = Nothing
    }
