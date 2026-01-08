-- | Application entry point.
-- Provides both single-queue and multi-queue processing capabilities.
module Shibuya.App
  ( -- * Single Queue
    runApp,

    -- * Multi-Queue
    QueueProcessor (..),
    AppHandle (..),
    runAppMulti,

    -- * AppHandle Operations
    getAppMetrics,
    stopApp,
    waitApp,

    -- * Errors
    AppError (..),

    -- * Re-exports
    ProcessorId (..),
    ProcessorMetrics (..),
    Strategy (..),
  )
where

import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, (:>))
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), validatePolicy)
import Shibuya.Runner (RunnerConfig (..))
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
import Shibuya.Runner.Serial (runSerial)
import Shibuya.Runner.Supervised
  ( SupervisedProcessor (..),
    isDone,
    runSupervised,
  )
import UnliftIO (SomeException, catch, displayException)
import UnliftIO.Concurrent (threadDelay)
import Prelude hiding (Ordering)

-- | Application errors.
data AppError
  = -- | Invalid policy configuration
    PolicyValidationError !Text
  | -- | Adapter error
    AdapterError !Text
  | -- | Handler error
    HandlerError !Text
  | -- | Runtime error
    RuntimeError !Text
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- Single Queue API
--------------------------------------------------------------------------------

-- | Run the message processing application with a single queue.
-- This is the simple entry point for single-adapter setups.
runApp ::
  (IOE :> es) =>
  RunnerConfig es msg ->
  Eff es (Either AppError ())
runApp config = do
  -- Validate policy
  case validatePolicy config.ordering config.concurrency of
    Left err -> pure $ Left $ PolicyValidationError err
    Right () -> runWithRunner config

-- | Run with the appropriate runner based on concurrency config.
runWithRunner ::
  (IOE :> es) =>
  RunnerConfig es msg ->
  Eff es (Either AppError ())
runWithRunner config = do
  let size = fromIntegral config.inboxSize

  -- Dispatch to appropriate runner based on concurrency mode
  result <-
    catch
      ( case config.concurrency of
          Serial -> do
            runSerial size config.adapter config.handler
            pure $ Right ()
          Ahead _n -> do
            -- TODO: Implement ahead-of-time prefetch runner
            runSerial size config.adapter config.handler
            pure $ Right ()
          Async _n -> do
            -- TODO: Implement async concurrent runner
            runSerial size config.adapter config.handler
            pure $ Right ()
      )
      ( \(e :: SomeException) ->
          pure $ Left $ RuntimeError $ Text.pack $ displayException e
      )

  -- Call adapter shutdown
  config.adapter.shutdown

  pure result

--------------------------------------------------------------------------------
-- Multi-Queue API
--------------------------------------------------------------------------------

-- | A queue processor pairs an adapter with its handler.
-- The message type is existentially hidden, allowing heterogeneous queues.
data QueueProcessor es where
  QueueProcessor ::
    { adapter :: Adapter es msg,
      handler :: Handler es msg
    } ->
    QueueProcessor es

-- | Handle for a running multi-queue application.
-- Provides introspection and control over all processors.
data AppHandle es = AppHandle
  { -- | The master coordinator
    master :: !Master,
    -- | Map of processor IDs to their handles
    processors :: !(Map ProcessorId (SupervisedProcessor, QueueProcessor es))
  }

-- | Run multiple queue processors concurrently.
--
-- Each processor runs independently under NQE supervision.
-- Returns immediately with a handle for introspection and control.
--
-- Example:
--
-- @
-- result <- runAppMulti OneForOne
--   [ ("orders", QueueProcessor ordersAdapter ordersHandler)
--   , ("events", QueueProcessor eventsAdapter eventsHandler)
--   ]
-- @
runAppMulti ::
  (IOE :> es) =>
  -- | Supervision strategy
  Strategy ->
  -- | Inbox size for backpressure
  Int ->
  -- | Named processors
  [(ProcessorId, QueueProcessor es)] ->
  Eff es (Either AppError (AppHandle es))
runAppMulti strategy inboxSize namedProcessors = do
  catch
    ( do
        -- Start the master coordinator
        master <- startMaster strategy

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
        pure $ Left $ RuntimeError $ Text.pack $ displayException e
    )

-- | Spawn all processors under supervision.
spawnProcessors ::
  (IOE :> es) =>
  Master ->
  Natural ->
  [(ProcessorId, QueueProcessor es)] ->
  Eff es [(ProcessorId, (SupervisedProcessor, QueueProcessor es))]
spawnProcessors master inboxSize = traverse spawnOne
  where
    spawnOne (procId, qp@(QueueProcessor adapter handler)) = do
      sp <- runSupervised master inboxSize procId adapter handler
      pure (procId, (sp, qp))

--------------------------------------------------------------------------------
-- AppHandle Operations
--------------------------------------------------------------------------------

-- | Get metrics for all processors.
getAppMetrics :: (IOE :> es) => AppHandle es -> Eff es MetricsMap
getAppMetrics appHandle = getAllMetrics appHandle.master

-- | Gracefully stop all processors and shut down the master.
stopApp :: (IOE :> es) => AppHandle es -> Eff es ()
stopApp appHandle = do
  -- Shutdown all adapters
  mapM_ shutdownAdapter (Map.elems appHandle.processors)
  -- Stop the master
  stopMaster appHandle.master
  where
    shutdownAdapter (_, QueueProcessor adapter _) = adapter.shutdown

-- | Wait for all processors to complete.
-- For infinite streams, this will block forever.
-- Use 'stopApp' to gracefully terminate.
waitApp :: (IOE :> es) => AppHandle es -> Eff es ()
waitApp appHandle = waitAll (Map.elems appHandle.processors)
  where
    waitAll [] = pure ()
    waitAll procs = do
      -- Check if all are done
      allDone <- and <$> traverse (\(sp, _) -> isDone sp) procs
      if allDone
        then pure ()
        else do
          -- Poll every 100ms
          liftIO $ threadDelay 100000
          waitAll procs
