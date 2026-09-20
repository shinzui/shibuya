-- | Application entry point for running Shibuya queue processors.
module Shibuya.App
  ( -- * Running Processors
    runApp,
    AppConfig (..),
    defaultAppConfig,
    QueueProcessor (..),
    mkProcessor,
    mkBatchProcessor,
    AppHandle,

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
    Master,
    getAllMetrics,
    getAllMetricsIO,
    getProcessorMetrics,
    getProcessorMetricsIO,

    -- * Batch API (re-exported from "Shibuya.Batch")
    module Shibuya.Batch,

    -- * Re-exports
    ProcessorId (..),
    ProcessorMetrics (..),
  )
where

import Control.Concurrent.NQE.Supervisor qualified as NQE
import Control.Concurrent.STM
  ( STM,
    atomically,
    check,
    newEmptyTMVarIO,
    newTVarIO,
    orElse,
    putTMVar,
    readTMVar,
    readTVar,
    registerDelay,
    writeTVar,
  )
import Control.Monad (forM, forM_, void)
import Data.Bifunctor (first)
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, Limit (..), Persistence (..), UnliftStrategy (..), liftIO, withEffToIO, (:>))
import Effectful.Exception qualified as Exception
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Batch
import Shibuya.Core.Error (ConfigError (..), HandlerError (..), PolicyError (..), RuntimeError (..))
import Shibuya.Core.Metrics
  ( MetricsMap,
    ProcessorId (..),
    ProcessorMetrics (..),
  )
import Shibuya.Internal.App
  ( AppHandle (..),
    OwnershipFailure (..),
    QueueProcessor (..),
    acquireOwned,
    mkBatchProcessor,
    mkProcessor,
  )
import Shibuya.Internal.Runner.Master
  ( Master,
    getAllMetrics,
    getAllMetricsIO,
    getProcessorMetrics,
    getProcessorMetricsIO,
    markProcessorDraining,
    startMaster,
    stopMaster,
  )
import Shibuya.Internal.Runner.Supervised
  ( SupervisedProcessor (..),
    runSupervised,
    runSupervisedBatch,
  )
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..), validatePolicy)
import Shibuya.Telemetry.Effect (Tracing)
import UnliftIO (SomeException, displayException)
import UnliftIO qualified as UIO

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
    -- @AckHalt@, do not stop sibling processors.
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
    drainTimeout :: !NominalDiffTime,
    -- | Maximum time for adapter shutdown plus graceful draining before
    -- forced supervisor stop begins.
    -- Default: 60 seconds.
    totalShutdownTimeout :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

-- | Default shutdown configuration with a 30 second drain timeout and a
-- 60 second bound on the graceful shutdown phase.
defaultShutdownConfig :: ShutdownConfig
defaultShutdownConfig = ShutdownConfig {drainTimeout = 30, totalShutdownTimeout = 60}

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
  | -- | Invalid application configuration
    AppConfigInvalid !ConfigError
  deriving stock (Eq, Show)

-- | Configuration for @runApp@.
data AppConfig = AppConfig
  { -- | How processor failures affect siblings.
    strategy :: !SupervisionStrategy,
    -- | Bounded-inbox capacity per processor (backpressure). Must be >= 1.
    inboxSize :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | 'IgnoreFailures' with an inbox of 100.
defaultAppConfig :: AppConfig
defaultAppConfig = AppConfig {strategy = IgnoreFailures, inboxSize = 100}

-- | Run queue processors concurrently under NQE supervision.
--
-- Each processor runs independently. Returns immediately with a handle
-- for introspection and control.
--
-- Example:
--
-- @
-- result <- runApp defaultAppConfig
--   [ ("orders", QueueProcessor ordersAdapter ordersHandler)
--   , ("events", QueueProcessor eventsAdapter eventsHandler)
--   ]
-- @
runApp ::
  (IOE :> es, Tracing :> es) =>
  -- | Application configuration
  AppConfig ->
  -- | Named processors
  [(ProcessorId, QueueProcessor es)] ->
  Eff es (Either AppError (AppHandle es))
runApp config namedProcessors =
  -- Validate all policies (and batch configs) first
  case validateAppConfig config *> validateUniqueProcessorIds namedProcessors *> validateAllPolicies namedProcessors of
    Left err -> pure $ Left err
    Right () -> do
      let nqeStrategy = toNQEStrategy config.strategy
      startupResult <-
        acquireOwned
          (startMaster nqeStrategy)
          stopMaster
          ( \master -> do
              processors <- spawnProcessors master (fromIntegral config.inboxSize) namedProcessors
              shutdownStarted <- liftIO $ newTVarIO False
              shutdownResult <- liftIO newEmptyTMVarIO
              pure
                AppHandle
                  { master = master,
                    processors = Map.fromList processors,
                    shutdownStarted,
                    shutdownResult
                  }
          )
      case startupResult of
        Right appHandle -> pure $ Right appHandle
        Left (OwnerAcquisitionFailed failure) -> startupFailure failure
        Left (OwnedActionFailed failure cleanupFailure) ->
          startupFailureWithCleanup failure cleanupFailure
  where
    startupFailure failure
      | Exception.isAsyncException failure = Exception.throwIO failure
      | otherwise =
          pure $ Left $ AppRuntimeError $ SupervisorFailed $ Text.pack $ displayException failure

    startupFailureWithCleanup failure cleanupFailure
      | Exception.isAsyncException failure = Exception.throwIO failure
      | otherwise =
          let cleanupSuffix = case cleanupFailure of
                Nothing -> ""
                Just cleanupException ->
                  "; supervisor cleanup also failed: " <> Text.pack (displayException cleanupException)
           in pure $
                Left $
                  AppRuntimeError $
                    SupervisorFailed $
                      Text.pack (displayException failure) <> cleanupSuffix

-- | Validate app configuration before starting any processor.
validateAppConfig :: AppConfig -> Either AppError ()
validateAppConfig config
  | config.inboxSize < 1 = Left $ AppConfigInvalid $ InvalidInboxSize config.inboxSize
  | otherwise = Right ()

-- | Reject duplicate processor identifiers before the master or any adapter is
-- acquired. Keeping this separate from handle construction prevents a live
-- processor from being silently discarded by 'Map.fromList'.
validateUniqueProcessorIds :: [(ProcessorId, QueueProcessor es)] -> Either AppError ()
validateUniqueProcessorIds = go Set.empty
  where
    go _ [] = Right ()
    go seen ((pid, _) : rest)
      | pid `Set.member` seen = Left $ AppConfigInvalid $ DuplicateProcessorId pid
      | otherwise = go (Set.insert pid seen) rest

-- | Validate all processor policies (and batch configs) before starting.
validateAllPolicies :: [(ProcessorId, QueueProcessor es)] -> Either AppError ()
validateAllPolicies = traverse_ validateOne
  where
    validateOne (_, qp) = case qp of
      QueueProcessor {ordering, concurrency} ->
        first AppPolicyError (validatePolicy ordering concurrency)
      BatchingProcessor {ordering, concurrency, batchConfig} -> do
        first AppPolicyError (validatePolicy ordering concurrency)
        validateBatchOrdering ordering concurrency
        first AppBatchConfigError (validateBatchConfig batchConfig)

    validateBatchOrdering PartitionedInOrder (Ahead _) =
      Left $
        AppPolicyError $
          InvalidPolicyCombo
            "PartitionedInOrder with Ahead/Async is supported only for QueueProcessor: batching processors schedule by BatchKey, not by Envelope.partition"
    validateBatchOrdering PartitionedInOrder (Async _) =
      Left $
        AppPolicyError $
          InvalidPolicyCombo
            "PartitionedInOrder with Ahead/Async is supported only for QueueProcessor: batching processors schedule by BatchKey, not by Envelope.partition"
    validateBatchOrdering _ _ = Right ()

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
      QueueProcessor {adapter, handler, ordering, concurrency} -> do
        sp <- runSupervised master inboxSize procId ordering concurrency adapter handler
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
-- Uses 'defaultShutdownConfig' (30 second drain timeout, 60 second graceful-phase bound).
-- For custom timeout, use 'stopAppGracefully'.
stopApp :: (IOE :> es) => AppHandle es -> Eff es ()
stopApp = void . stopAppGracefully defaultShutdownConfig

-- | Gracefully stop all processors with configurable drain and total timeout.
--
-- Shutdown sequence:
-- 1. Signal all adapters to stop producing (close source streams)
-- 2. Wait for processors to drain in-flight messages (with timeout)
-- 3. Force stop any remaining processors after timeout
-- 4. Stop the master coordinator
--
-- Returns whether all processors drained cleanly (True) or were forced (False).
stopAppGracefully :: (IOE :> es) => ShutdownConfig -> AppHandle es -> Eff es Bool
stopAppGracefully config appHandle =
  Exception.mask $ \restore -> do
    isLeader <-
      liftIO $
        atomically $ do
          started <- readTVar appHandle.shutdownStarted
          if started
            then pure False
            else writeTVar appHandle.shutdownStarted True >> pure True
    if isLeader
      then do
        result <- Exception.try @SomeException (restore performShutdown)
        liftIO $ atomically $ putTMVar appHandle.shutdownResult result
        either Exception.throwIO pure result
      else do
        result <- restore $ liftIO $ atomically $ readTMVar appHandle.shutdownResult
        either Exception.throwIO pure result
  where
    performShutdown = Exception.mask $ \restore -> do
      let totalTimeoutMicros = nominalToMicros config.totalShutdownTimeout
      outcome <-
        Exception.try $
          restore $
            withEffToIO (ConcUnlift Persistent Unlimited) $ \runInIO ->
              UIO.timeout totalTimeoutMicros (runInIO shutdownAndDrain)

      -- Master cleanup is unconditional: adapter failures, external cancellation,
      -- drain cancellation, and the total deadline all converge here.
      stopOutcome <- Exception.try @SomeException (stopMaster appHandle.master)
      case outcome of
        Left (primaryFailure :: SomeException) -> Exception.throwIO primaryFailure
        Right Nothing -> finishStopOutcome stopOutcome False
        Right (Just drained) -> finishStopOutcome stopOutcome drained

    shutdownAndDrain = do
      forM_ (Map.keys appHandle.processors) $
        markProcessorDraining appHandle.master

      -- Catch only synchronous adapter failures. External cancellation and the
      -- total timeout must abort this phase so the master is force-stopped.
      shutdownResults <-
        forM (Map.elems appHandle.processors) $ \processor ->
          Exception.trySync (shutdownAdapter processor)

      case [failure | Left failure <- shutdownResults] of
        firstFailure : _ -> Exception.throwIO firstFailure
        [] -> do
          let drainTimeoutMicros = nominalToMicros config.drainTimeout
          liftIO $ waitForDrainWithTimeout drainTimeoutMicros (Map.elems appHandle.processors)

    shutdownAdapter (_, qp) = case qp of
      QueueProcessor {adapter} -> adapter.shutdown
      BatchingProcessor {adapter} -> adapter.shutdown

    finishStopOutcome (Left stopFailure) _ = Exception.throwIO stopFailure
    finishStopOutcome (Right ()) drained = pure drained

    nominalToMicros timeout = max 0 (floor (timeout * 1_000_000))

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
