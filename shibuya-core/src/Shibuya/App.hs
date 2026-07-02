-- | Application entry point for running Shibuya queue processors.
module Shibuya.App
  ( -- * Running Processors
    runApp,
    QueueProcessor (..),
    mkProcessor,
    mkBatchProcessor,
    AppHandle (..),

    -- * AppHandle Operations
    getAppMetrics,
    getAppMaster,
    stopApp,
    stopAppGracefully,
    waitApp,

    -- * Shutdown Configuration
    ShutdownConfig (..),
    defaultShutdownConfig,

    -- * Supervision Strategy
    SupervisionStrategy (..),

    -- * Errors
    AppError (..),

    -- * Batch API (re-exported from "Shibuya.Batch")
    module Shibuya.Batch,

    -- * Re-exports
    ProcessorId (..),
    ProcessorMetrics (..),
  )
where

import Control.Concurrent.NQE.Supervisor qualified as NQE
import Control.Concurrent.STM (STM, atomically, check, orElse, readTVar, registerDelay)
import Control.Monad (forM_, void)
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, liftIO, (:>))
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Batch
import Shibuya.Core.Error (HandlerError (..), PolicyError (..), RuntimeError (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), Ordering (..), validatePolicy)
import Shibuya.Runner.Master
  ( Master,
    getAllMetrics,
    startMaster,
    stopMaster,
  )
import Shibuya.Runner.Metrics
  ( MetricsMap,
    ProcessorId (..),
    ProcessorMetrics (..),
  )
import Shibuya.Runner.Supervised
  ( SupervisedProcessor (..),
    runSupervised,
    runSupervisedBatch,
  )
import Shibuya.Telemetry.Effect (Tracing)
import UnliftIO (SomeException, catch, displayException)
import Prelude hiding (Ordering)

--------------------------------------------------------------------------------
-- Supervision Strategy
--------------------------------------------------------------------------------

-- | Supervision strategy for processor failures.
--
-- This is Shibuya's own type that maps to NQE's supervision strategies,
-- decoupling users from the NQE library.
data SupervisionStrategy
  = -- | Ignore all child exits, keep running.
    -- Failed processors are marked as Failed in metrics but don't affect others.
    IgnoreFailures
  | -- | Stop all processors if any fails.
    -- A single processor failure triggers shutdown of all processors.
    -- Graceful exits, including finite streams completing and handlers returning
    -- 'AckHalt', do not stop sibling processors.
    StopAllOnFailure
  deriving stock (Eq, Show, Generic)

-- | Convert Shibuya's strategy type to NQE's internal type.
toNQEStrategy :: SupervisionStrategy -> NQE.Strategy
toNQEStrategy = \case
  IgnoreFailures -> NQE.IgnoreAll
  StopAllOnFailure -> NQE.IgnoreGraceful

--------------------------------------------------------------------------------
-- Shutdown Configuration
--------------------------------------------------------------------------------

-- | Configuration for graceful shutdown behavior.
data ShutdownConfig = ShutdownConfig
  { -- | Maximum time to wait for in-flight messages to drain.
    -- After this timeout, remaining processors are forcefully stopped.
    -- Default: 30 seconds.
    drainTimeout :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

-- | Default shutdown configuration with 30 second drain timeout.
defaultShutdownConfig :: ShutdownConfig
defaultShutdownConfig = ShutdownConfig {drainTimeout = 30}

--------------------------------------------------------------------------------
-- Errors
--------------------------------------------------------------------------------

-- | Application errors.
-- Uses structured error types from Shibuya.Core.Error.
data AppError
  = -- | Invalid policy configuration
    AppPolicyError !PolicyError
  | -- | Handler execution error
    AppHandlerError !HandlerError
  | -- | Runtime error
    AppRuntimeError !RuntimeError
  | -- | Invalid batch configuration for a 'BatchingProcessor'
    AppBatchConfigError !BatchConfigError
  deriving stock (Eq, Show)

-- | A queue processor pairs an adapter with a handler. The message type is
-- existentially hidden, allowing heterogeneous queues in one 'runApp' call.
--
-- 'QueueProcessor' processes one message at a time; 'BatchingProcessor' groups
-- messages into batches (see "Shibuya.Batch") and runs a 'BatchHandler' over each.
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg,
      handler :: Handler es msg,
      ordering :: Ordering,
      concurrency :: Concurrency
    } ->
    QueueProcessor es
  BatchingProcessor ::
    { adapter :: Adapter es msg,
      batchHandler :: BatchHandler es msg,
      batchConfig :: BatchConfig es msg,
      ordering :: Ordering,
      concurrency :: Concurrency
    } ->
    QueueProcessor es

-- | Convenience constructor with default policies (Unordered + Serial).
-- Provides backward compatibility with existing code.
mkProcessor :: Adapter es msg -> Handler es msg -> QueueProcessor es
mkProcessor adapter handler = QueueProcessor adapter handler Unordered Serial

-- | Convenience constructor for a batching processor with safe default policies
-- (Unordered ordering + Serial concurrency, i.e. one batch at a time).
mkBatchProcessor ::
  Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es
mkBatchProcessor adapter batchHandler batchConfig =
  BatchingProcessor adapter batchHandler batchConfig Unordered Serial

-- | Handle for a running multi-queue application.
-- Provides introspection and control over all processors.
data AppHandle es = AppHandle
  { -- | The master coordinator
    master :: !Master,
    -- | Map of processor IDs to their handles
    processors :: !(Map ProcessorId (SupervisedProcessor, QueueProcessor es))
  }

-- | Run queue processors concurrently under NQE supervision.
--
-- Each processor runs independently. Returns immediately with a handle
-- for introspection and control.
--
-- Example:
--
-- @
-- result <- runApp IgnoreFailures 100
--   [ ("orders", QueueProcessor ordersAdapter ordersHandler)
--   , ("events", QueueProcessor eventsAdapter eventsHandler)
--   ]
-- @
runApp ::
  (IOE :> es, Tracing :> es) =>
  -- | Supervision strategy
  SupervisionStrategy ->
  -- | Inbox size for backpressure
  Int ->
  -- | Named processors
  [(ProcessorId, QueueProcessor es)] ->
  Eff es (Either AppError (AppHandle es))
runApp strategy inboxSize namedProcessors =
  -- Validate all policies (and batch configs) first
  case validateAllPolicies namedProcessors of
    Left err -> pure $ Left err
    Right () -> do
      let nqeStrategy = toNQEStrategy strategy
      catch
        ( do
            -- Start the master coordinator
            master <- startMaster nqeStrategy

            -- Spawn each processor under supervision
            processors <- spawnProcessors master (fromIntegral inboxSize) namedProcessors

            pure $
              Right
                AppHandle
                  { master = master,
                    processors = Map.fromList processors
                  }
        )
        ( \(e :: SomeException) ->
            pure $ Left $ AppRuntimeError $ SupervisorFailed $ Text.pack $ displayException e
        )

-- | Validate all processor policies (and batch configs) before starting.
validateAllPolicies :: [(ProcessorId, QueueProcessor es)] -> Either AppError ()
validateAllPolicies = traverse_ validateOne
  where
    validateOne (_, qp) = case qp of
      QueueProcessor {ordering, concurrency} ->
        first AppPolicyError (validatePolicy ordering concurrency)
      BatchingProcessor {ordering, concurrency, batchConfig} -> do
        first AppPolicyError (validatePolicy ordering concurrency)
        first AppBatchConfigError (validateBatchConfig batchConfig)

-- | Spawn all processors under supervision.
spawnProcessors ::
  (IOE :> es, Tracing :> es) =>
  Master ->
  Natural ->
  [(ProcessorId, QueueProcessor es)] ->
  Eff es [(ProcessorId, (SupervisedProcessor, QueueProcessor es))]
spawnProcessors master inboxSize = traverse spawnOne
  where
    spawnOne (procId, qp) = case qp of
      QueueProcessor {adapter, handler, concurrency} -> do
        sp <- runSupervised master inboxSize procId concurrency adapter handler
        pure (procId, (sp, qp))
      BatchingProcessor {adapter, batchHandler, batchConfig, concurrency} -> do
        sp <-
          runSupervisedBatch
            master
            inboxSize
            procId
            concurrency
            batchConfig
            adapter
            batchHandler
        pure (procId, (sp, qp))

--------------------------------------------------------------------------------
-- AppHandle Operations
--------------------------------------------------------------------------------

-- | Get metrics for all processors.
getAppMetrics :: (IOE :> es) => AppHandle es -> Eff es MetricsMap
getAppMetrics appHandle = getAllMetrics appHandle.master

-- | Get the master handle for direct access.
-- This is useful for integrating with the metrics server.
getAppMaster :: AppHandle es -> Master
getAppMaster appHandle = appHandle.master

-- | Gracefully stop all processors with default configuration.
-- Uses 'defaultShutdownConfig' (30 second drain timeout).
-- For custom timeout, use 'stopAppGracefully'.
stopApp :: (IOE :> es) => AppHandle es -> Eff es ()
stopApp = void . stopAppGracefully defaultShutdownConfig

-- | Gracefully stop all processors with configurable drain timeout.
--
-- Shutdown sequence:
-- 1. Signal all adapters to stop producing (close source streams)
-- 2. Wait for processors to drain in-flight messages (with timeout)
-- 3. Force stop any remaining processors after timeout
-- 4. Stop the master coordinator
--
-- Returns whether all processors drained cleanly (True) or were forced (False).
stopAppGracefully :: (IOE :> es) => ShutdownConfig -> AppHandle es -> Eff es Bool
stopAppGracefully config appHandle = do
  -- 1. Signal adapters to stop producing
  mapM_ shutdownAdapter (Map.elems appHandle.processors)

  -- 2. Wait for drain with timeout
  let timeoutMicros = floor (config.drainTimeout * 1_000_000)
  drained <- liftIO $ waitForDrainWithTimeout timeoutMicros (Map.elems appHandle.processors)

  -- 3. Log warning if forced shutdown (caller can check return value)
  -- Note: We don't log here to avoid IO dependencies, caller can log if needed

  -- 4. Stop master (cancels any remaining processors)
  stopMaster appHandle.master

  pure drained
  where
    shutdownAdapter (_, qp) = case qp of
      QueueProcessor {adapter} -> adapter.shutdown
      BatchingProcessor {adapter} -> adapter.shutdown

-- | Wait for all processors to be done, with timeout.
-- Returns True if all drained cleanly, False if timeout occurred.
-- Note: Requires -threaded RTS for registerDelay to work properly.
waitForDrainWithTimeout :: Int -> [(SupervisedProcessor, a)] -> IO Bool
waitForDrainWithTimeout timeoutMicros processors = do
  -- Create a timeout TVar that becomes True after the deadline
  timeoutVar <- registerDelay timeoutMicros

  -- Wait for either all done or timeout
  atomically $
    (allDone processors >> pure True)
      `orElse` (readTVar timeoutVar >>= check >> pure False)
  where
    allDone :: [(SupervisedProcessor, a)] -> STM ()
    allDone procs = forM_ procs $ \(sp, _) -> readTVar sp.done >>= check

-- | Wait for all processors to complete.
-- For infinite streams, this will block forever.
-- Use 'stopApp' to gracefully terminate.
--
-- Uses STM to block efficiently until all processors are done,
-- rather than polling.
waitApp :: (IOE :> es) => AppHandle es -> Eff es ()
waitApp appHandle = liftIO $ atomically $ do
  -- Block until all done TVars are True
  forM_ (Map.elems appHandle.processors) $ \(sp, _) ->
    readTVar sp.done >>= check
