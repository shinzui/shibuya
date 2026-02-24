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
    DeadLetterTarget (..),
    FifoConfig (..),
    FifoReadStrategy (..),
    PrefetchConfig (..),

    -- * Smart Constructors
    directDeadLetter,
    topicDeadLetter,

    -- * Defaults
    defaultConfig,
    defaultPollingConfig,
    defaultPrefetchConfig,

    -- * Topic Management (pgmq 1.11.0+)
    bindQueueTopics,
    unbindQueueTopics,
    listQueueTopicBindings,
    testTopicRouting,

    -- * Re-exports from pgmq
    QueueName,
    parseQueueName,
    queueNameToText,

    -- ** Topic Types (pgmq 1.11.0+)
    RoutingKey,
    parseRoutingKey,
    routingKeyToText,
    TopicPattern,
    parseTopicPattern,
    topicPatternToText,
    TopicBinding (..),
    RoutingMatch (..),
  )
where

import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (Value)
import Effectful (Eff, IOE, (:>))
import Pgmq.Effectful.Effect (Pgmq)
import Pgmq.Effectful.Effect qualified as PgmqEff
import Pgmq.Hasql.Statements.Types qualified as PgmqTypes
import Pgmq.Types
  ( QueueName,
    RoutingKey,
    RoutingMatch (..),
    TopicBinding (..),
    TopicPattern,
    parseQueueName,
    parseRoutingKey,
    parseTopicPattern,
    queueNameToText,
    routingKeyToText,
    topicPatternToText,
  )
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Pgmq.Config
  ( DeadLetterConfig (..),
    DeadLetterTarget (..),
    FifoConfig (..),
    FifoReadStrategy (..),
    PgmqAdapterConfig (..),
    PollingConfig (..),
    PrefetchConfig (..),
    defaultConfig,
    defaultPollingConfig,
    defaultPrefetchConfig,
    directDeadLetter,
    topicDeadLetter,
  )
import Shibuya.Adapter.Pgmq.Internal (pgmqSource, pgmqSourceWithPrefetch)
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import Streamly.Data.Stream.Prelude qualified as StreamP

-- | Create a PGMQ adapter with the given configuration.
--
-- The adapter provides:
--
-- * A stream of messages from the configured queue
-- * Automatic visibility timeout management
-- * Lease extension capability for long-running handlers
-- * Dead-letter queue support (optional)
-- * FIFO ordering support (optional)
-- * Concurrent prefetching (optional, via 'prefetchConfig')
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
--
-- == Prefetching
--
-- To enable concurrent prefetching (polls next batch while processing current):
--
-- @
-- let config = (defaultConfig queueName) { prefetchConfig = Just defaultPrefetchConfig }
-- adapter <- pgmqAdapter config
-- @
pgmqAdapter ::
  (Pgmq :> es, IOE :> es) =>
  PgmqAdapterConfig ->
  Eff es (Adapter es Value)
pgmqAdapter config = do
  -- Create shutdown signal
  shutdownVar <- liftIO $ newTVarIO False

  -- Select source based on prefetch configuration
  let messageSource = case config.prefetchConfig of
        Nothing ->
          -- No prefetching - simple sequential polling
          pgmqSource config
        Just prefetch ->
          -- Concurrent prefetching enabled
          let prefetchSettings = StreamP.maxBuffer (fromIntegral prefetch.bufferSize)
           in pgmqSourceWithPrefetch prefetchSettings config

  pure
    Adapter
      { adapterName = "pgmq:" <> queueNameToText config.queueName,
        source = takeUntilShutdown shutdownVar messageSource,
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
    isShutdown <- liftIO $ readTVarIO shutdownVar
    pure (not isShutdown)

--------------------------------------------------------------------------------
-- Topic Management (pgmq 1.11.0+)
--------------------------------------------------------------------------------

-- | Bind multiple topic patterns to a queue.
-- Each pattern is bound idempotently (re-binding an existing pattern is a no-op).
--
-- Example:
--
-- @
-- bindQueueTopics ordersQueueName
--   [ pattern | Right pattern <- [parseTopicPattern "orders.#", parseTopicPattern "*.created"] ]
-- @
bindQueueTopics ::
  (Pgmq :> es) =>
  QueueName ->
  [TopicPattern] ->
  Eff es ()
bindQueueTopics queueName patterns =
  forM_ patterns $ \tp ->
    PgmqEff.bindTopic
      PgmqTypes.BindTopic
        { topicPattern = tp,
          queueName = queueName
        }

-- | Unbind multiple topic patterns from a queue.
-- Returns silently for patterns that were not bound.
unbindQueueTopics ::
  (Pgmq :> es) =>
  QueueName ->
  [TopicPattern] ->
  Eff es ()
unbindQueueTopics queueName patterns =
  forM_ patterns $ \tp ->
    PgmqEff.unbindTopic
      PgmqTypes.UnbindTopic
        { topicPattern = tp,
          queueName = queueName
        }

-- | List all topic bindings for a specific queue.
listQueueTopicBindings ::
  (Pgmq :> es) =>
  QueueName ->
  Eff es [TopicBinding]
listQueueTopicBindings = PgmqEff.listTopicBindingsForQueue

-- | Test which queues a routing key would match, without sending any messages.
-- Useful for validating topic routing configuration.
testTopicRouting ::
  (Pgmq :> es) =>
  RoutingKey ->
  Eff es [RoutingMatch]
testTopicRouting = PgmqEff.testRouting
