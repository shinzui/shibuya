-- | PGMQ adapter for the Shibuya queue processing framework.
--
-- This adapter integrates with [pgmq](https://github.com/tembo-io/pgmq)
-- (PostgreSQL Message Queue) using the pgmq-hs client library.
--
-- == Example Usage
--
-- @
-- import Shibuya.App (runApp, QueueProcessor (..))
-- import Shibuya.Adapter.Pgmq
-- import Pgmq.Effectful (runPgmq)
-- import Hasql.Pool qualified as Pool
--
-- main :: IO ()
-- main = do
--   pool <- Pool.acquire 10 Nothing connectionSettings
--   case parseQueueName "orders" of
--     Left err -> print err
--     Right queueName -> do
--       let config = defaultConfig queueName
--       runEff
--         . runPgmq pool
--         $ do
--             adapter <- pgmqAdapter config
--             result <- runApp IgnoreFailures 100
--               [ (ProcessorId "orders", QueueProcessor adapter handleOrder)
--               ]
--             -- ...
-- @
--
-- == Message Lifecycle
--
-- 1. Messages are read from pgmq with a visibility timeout
-- 2. During processing, messages are invisible to other consumers
-- 3. On 'AckOk', messages are deleted from the queue
-- 4. On 'AckRetry', visibility timeout is extended
-- 5. On 'AckDeadLetter', messages are archived or sent to DLQ
-- 6. On 'AckHalt', visibility timeout is extended and processor stops
--
-- == Retry Handling
--
-- pgmq tracks retry attempts via the 'readCount' field. When a message's
-- 'readCount' exceeds 'maxRetries' in the config, it is automatically
-- dead-lettered before being passed to the handler.
--
-- == FIFO Support
--
-- For ordered message processing, configure 'fifoConfig'. Messages are
-- grouped by the @x-pgmq-group@ header. Two strategies are available:
--
-- * 'ThroughputOptimized': Fill batches from the same group (SQS-like)
-- * 'RoundRobin': Fair distribution across groups
module Shibuya.Adapter.Pgmq
  ( -- * Adapter
    pgmqAdapter,

    -- * Configuration
    PgmqAdapterConfig (..),
    PollingConfig (..),
    DeadLetterConfig (..),
    FifoConfig (..),
    FifoReadStrategy (..),

    -- * Defaults
    defaultConfig,
    defaultPollingConfig,

    -- * Re-exports from pgmq
    QueueName,
    parseQueueName,
    queueNameToText,
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Effectful (Eff, IOE, (:>))
import Pgmq.Effectful.Effect (Pgmq)
import Pgmq.Types (QueueName, parseQueueName, queueNameToText)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Pgmq.Config
  ( DeadLetterConfig (..),
    FifoConfig (..),
    FifoReadStrategy (..),
    PgmqAdapterConfig (..),
    PollingConfig (..),
    defaultConfig,
    defaultPollingConfig,
  )
import Shibuya.Adapter.Pgmq.Internal (pgmqSource)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream

-- | Create a PGMQ adapter with the given configuration.
--
-- The adapter provides:
--
-- * A stream of messages from the configured queue
-- * Automatic visibility timeout management
-- * Lease extension capability for long-running handlers
-- * Dead-letter queue support (optional)
-- * FIFO ordering support (optional)
--
-- == Effect Requirements
--
-- This adapter requires the 'Pgmq' effect to be available in your effect stack.
-- You must run 'Pgmq.Effectful.runPgmq' with a connection pool before using
-- this adapter.
--
-- == Example
--
-- @
-- adapter <- pgmqAdapter config
-- runApp IgnoreFailures 100
--   [ (ProcessorId "my-processor", QueueProcessor adapter myHandler)
--   ]
-- @
pgmqAdapter ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Eff es (Adapter es Value)
pgmqAdapter config = do
  -- Create shutdown signal
  shutdownVar <- liftIO $ newTVarIO False

  pure
    Adapter
      { adapterName = "pgmq:" <> queueNameToText config.queueName,
        source = takeUntilShutdown shutdownVar (pgmqSource config),
        shutdown = liftIO $ atomically $ writeTVar shutdownVar True
      }

-- | Take from stream until shutdown signal is set.
takeUntilShutdown ::
  (IOE :> es) =>
  TVar Bool ->
  Stream (Eff es) a ->
  Stream (Eff es) a
takeUntilShutdown shutdownVar =
  Stream.takeWhileM $ \_ -> do
    isShutdown <- liftIO $ atomically $ readTVar shutdownVar
    pure (not isShutdown)
