-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Master handle - owns the shared supervisor and metrics registry for queue processors.
-- Provides supervision, metrics collection, and control API.
--
-- Architecture:
-- - Holds a Supervisor for managing child processors
-- - Maintains TVar MetricsMap for O(1) metrics access
-- - Processors register their metrics TVars with the Master
module Shibuya.Internal.Runner.Master
  ( -- * Master Handle
    Master (..),
    MasterState (..),

    -- * Starting the Master
    startMaster,
    stopMaster,

    -- * Introspection
    getAllMetrics,
    getAllMetricsIO,
    getProcessorMetrics,
    getProcessorMetricsIO,
    MasterPhase (..),
    getMasterPhase,
    getMasterPhaseIO,
    ProcessorLifecycle (..),
    LifecycleSnapshot,
    getLifecycleSnapshot,
    getLifecycleSnapshotIO,

    -- * Processor Management
    registerProcessor,
    registerProcessorWithPause,
    ProcessorEntry (..),
    PauseState (..),
    ControlOutcome (..),
    pauseProcessorIO,
    resumeProcessorIO,
    isProcessorPausedIO,
    pauseProcessor,
    resumeProcessor,
    isProcessorPaused,
    drainAndResume,
    unregisterProcessor,
    markMasterRunning,
    markMasterDraining,
    markProcessorDraining,
    markProcessorStopped,
    markProcessorStoppedIO,
    markProcessorFailed,
    markProcessorFailedIO,
  )
where

import Control.Concurrent.Async (asyncWithUnmask)
import Control.Concurrent.NQE.Process (Process (..), newMailbox)
import Control.Concurrent.NQE.Supervisor (Strategy (..), Supervisor)
import Control.Concurrent.NQE.Supervisor qualified as Supervisor
import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    retry,
    writeTVar,
  )
import Control.Exception qualified as Exception
import Control.Monad (forM_, void, when)
import Data.IORef (IORef, atomicModifyIORef', atomicWriteIORef, newIORef, readIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Effectful (Eff, IOE, liftIO, (:>))
import Shibuya.Core.Metrics
  ( MetricsHandle,
    MetricsMap,
    ProcessorId,
    ProcessorMetrics,
    sampleMetrics,
  )
import Shibuya.Core.Metrics qualified as Metrics
import Shibuya.Core.Types (MessageId)
import Shibuya.Internal.Runner.Pause
import Shibuya.Prelude
import UnliftIO (cancel)

-- | Master ownership and observation state.
data MasterState = MasterState
  { -- | Live metrics and retained lifecycle state share one STM ownership
    -- cell. Registration can therefore publish both atomically without adding
    -- another per-master TVar to the startup path.
    registry :: !(TVar MasterRegistry),
    -- | The master phase is sampled independently by health endpoints. Keeping
    -- it in an atomic reference avoids paying for a standalone STM transaction
    -- on every stop while processor registry updates remain transactional.
    phaseRef :: !(IORef MasterPhase),
    -- | The supervisor managing child processors
    supervisor :: !Supervisor,
    -- | Whether child failures should be linked into the spawning thread.
    -- Derived from the supervision strategy: True for KillAll/IgnoreGraceful
    -- (failure must reach the application), False for IgnoreAll/Notify.
    propagateFailures :: !Bool
  }
  deriving (Generic)

data MasterRegistry = MasterRegistry
  { liveMetrics :: !(Map ProcessorId ProcessorEntry),
    draining :: !Bool,
    lifecycles :: !LifecycleSnapshot
  }
  deriving (Generic)

-- | Lifecycle phase of the master itself. Processor terminal state is retained
-- separately in 'LifecycleSnapshot'.
data MasterPhase
  = MasterStarting
  | MasterRunning
  | MasterDraining
  | MasterStopped
  deriving stock (Eq, Show, Generic)

-- | Internal lifecycle state retained for the configured processor set.
data ProcessorLifecycle
  = LifecycleRunning
  | LifecycleDraining
  | LifecycleStopped
  | LifecycleFailed !Text !(Maybe MessageId)
  deriving stock (Eq, Show, Generic)

type LifecycleSnapshot = Map ProcessorId ProcessorLifecycle

-- | Master handle - owns the shared supervisor and metrics registry.
newtype Master = Master
  { -- | Direct access to master state
    state :: MasterState
  }
  deriving (Generic)

-- | Start the master process.
-- Returns a handle for accessing shared application state.
-- The caller is responsible for calling stopMaster when done.
--
-- The supervisor is deliberately not linked to the calling thread, which is why
-- this assembles the 'Process' itself instead of using 'Supervisor.supervisor':
-- NQE's @process@ always links. With no children left the supervisor can only be
-- woken through its mailbox, and the mailbox is reachable solely through this
-- handle, so a link would turn a dropped handle into an 'ExceptionInLinkedThread'
-- in the caller at the next major garbage collection. Unlinked, such a supervisor
-- is simply collected. Processor failures still reach the caller, exactly once,
-- through the per-processor links installed when 'propagateFailures' is set.
startMaster :: (IOE :> es) => Strategy -> Eff es Master
startMaster strategy = liftIO $ Exception.mask_ $ do
  (inbox, mailbox) <- newMailbox
  -- The parent stays masked through the ownership transfer, but the long-lived
  -- supervisor must run unmasked. Inheriting the parent's masking state makes
  -- every supervisor cycle retain exception machinery and materially regresses
  -- repeated startup/shutdown.
  supAsync <- asyncWithUnmask $ \unmask ->
    unmask (Supervisor.supervisorProcess strategy inbox)
  -- Everything after 'async' is a non-blocking ownership transfer under the
  -- mask. Cancellation is delivered only after the completed 'Master' returns
  -- to 'acquireOwned', which then owns cleanup; there is no interruptible gap
  -- that needs an extra exception frame here.
  let sup = Process supAsync mailbox
  registryVar <- newTVarIO $ MasterRegistry Map.empty False Map.empty
  phaseRef <- newIORef MasterStarting
  let propagate = case strategy of
        KillAll -> True
        IgnoreGraceful -> True
        IgnoreAll -> False
        Notify _ -> False
  pure Master {state = MasterState registryVar phaseRef sup propagate}

-- | Stop the master and all child processors.
-- Cancels the supervisor, which cancels all children via NQE's stopAll.
stopMaster :: (IOE :> es) => Master -> Eff es ()
stopMaster master = do
  drainAndResume master
  liftIO $ do
    atomicWriteIORef master.state.phaseRef MasterStopped
    cancel (getProcessAsync master.state.supervisor)

-- | Get metrics for all processors.
getAllMetrics :: (IOE :> es) => Master -> Eff es MetricsMap
getAllMetrics = liftIO . getAllMetricsIO

-- | Get metrics for all processors (IO version for web servers).
getAllMetricsIO :: Master -> IO MetricsMap
getAllMetricsIO master = do
  registry <- atomically $ readTVar master.state.registry
  traverse (sampleMetrics . (.metrics)) registry.liveMetrics

-- | Get metrics for a specific processor.
getProcessorMetrics :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
getProcessorMetrics master = liftIO . getProcessorMetricsIO master

-- | Get metrics for a specific processor (IO version for web servers).
getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
getProcessorMetricsIO master pid = do
  registry <- atomically $ readTVar master.state.registry
  traverse (sampleMetrics . (.metrics)) (Map.lookup pid registry.liveMetrics)

-- | Read the master lifecycle phase.
getMasterPhase :: (IOE :> es) => Master -> Eff es MasterPhase
getMasterPhase = liftIO . getMasterPhaseIO

-- | IO variant for health integrations.
getMasterPhaseIO :: Master -> IO MasterPhase
getMasterPhaseIO = readIORef . (.state.phaseRef)

-- | Read the retained processor lifecycle snapshot.
getLifecycleSnapshot :: (IOE :> es) => Master -> Eff es LifecycleSnapshot
getLifecycleSnapshot = liftIO . getLifecycleSnapshotIO

-- | IO variant for metrics and health integrations.
getLifecycleSnapshotIO :: Master -> IO LifecycleSnapshot
getLifecycleSnapshotIO master = (.lifecycles) <$> atomically (readTVar master.state.registry)

-- | Register a processor with the master.
-- The processor should call this with its metrics handle.
registerProcessor :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Eff es ()
registerProcessor master pid metricsHandle = registerProcessorWithPause master pid metricsHandle Nothing

-- | Register real intake control; the legacy wrapper has no control capability.
registerProcessorWithPause :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Maybe PauseHandle -> Eff es ()
registerProcessorWithPause master pid metricsHandle pauseHandle = liftIO $ atomically $ do
  registry <- readTVar master.state.registry
  when registry.draining $ do
    forM_ pauseHandle $ \h -> void (requestResumeSTM h)
    Metrics.markResumedSTM metricsHandle
  writeTVar
    master.state.registry
    registry
      { liveMetrics = Map.insert pid (ProcessorEntry metricsHandle pauseHandle) registry.liveMetrics,
        lifecycles = Map.insert pid (if registry.draining then LifecycleDraining else LifecycleRunning) registry.lifecycles
      }

-- | Unregister a processor from the master.
unregisterProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
unregisterProcessor master pid =
  liftIO $
    atomically $
      modifyTVar' master.state.registry $ \registry ->
        registry {liveMetrics = Map.delete pid registry.liveMetrics}

markMasterRunning :: (IOE :> es) => Master -> Eff es ()
markMasterRunning master = liftIO $ advanceMasterPhase master MasterRunning

markMasterDraining :: (IOE :> es) => Master -> Eff es ()
markMasterDraining master = liftIO $ advanceMasterPhase master MasterDraining

advanceMasterPhase :: Master -> MasterPhase -> IO ()
advanceMasterPhase master next =
  atomicModifyIORef' master.state.phaseRef $ \current ->
    (case current of MasterStopped -> MasterStopped; _ -> next, ())

markProcessorDraining :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
markProcessorDraining master pid =
  liftIO $
    atomically $
      modifyTVar' master.state.registry $ \registry ->
        registry
          { lifecycles =
              Map.adjust
                (\case LifecycleRunning -> LifecycleDraining; terminal -> terminal)
                pid
                registry.lifecycles
          }

markProcessorStopped :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
markProcessorStopped master = liftIO . markProcessorStoppedIO master

markProcessorStoppedIO :: Master -> ProcessorId -> IO ()
markProcessorStoppedIO master pid =
  atomically $
    modifyTVar' master.state.registry $ \registry ->
      registry
        { lifecycles =
            Map.adjust
              (\case LifecycleFailed failure messageId -> LifecycleFailed failure messageId; _ -> LifecycleStopped)
              pid
              registry.lifecycles
        }

markProcessorFailed :: (IOE :> es) => Master -> ProcessorId -> Text -> Maybe MessageId -> Eff es ()
markProcessorFailed master pid failure messageId =
  liftIO $ markProcessorFailedIO master pid failure messageId

markProcessorFailedIO :: Master -> ProcessorId -> Text -> Maybe MessageId -> IO ()
markProcessorFailedIO master pid failure messageId =
  atomically $
    modifyTVar' master.state.registry $ \registry ->
      registry
        { lifecycles = Map.insert pid (LifecycleFailed failure messageId) registry.lifecycles
        }

-- | Live observation and optional intake control have the same registry owner.
data ProcessorEntry = ProcessorEntry {metrics :: !MetricsHandle, pause :: !(Maybe PauseHandle)}

data PauseState = IntakeRunning | IntakePaused !UTCTime
  deriving stock (Eq, Show, Generic)

-- | Outcome and successful intake state captured by the same STM transaction.
data ControlOutcome
  = ControlApplied !PauseState
  | ControlAlreadyInState !PauseState
  | ControlNotFound
  | ControlNotControllable
  | ControlTerminal
  | ControlDraining
  deriving stock (Eq, Show, Generic)

controllable :: Master -> ProcessorId -> STM (Either ControlOutcome ProcessorEntry)
controllable master pid = do
  registry <- readTVar master.state.registry
  pure $ case Map.lookup pid registry.lifecycles of
    Nothing -> Left ControlNotFound
    Just LifecycleStopped -> Left ControlTerminal
    Just LifecycleFailed {} -> Left ControlTerminal
    Just LifecycleDraining -> Left ControlDraining
    _ | registry.draining -> Left ControlDraining
    _ -> case Map.lookup pid registry.liveMetrics of
      Just entry | Just _ <- entry.pause -> Right entry
      _ -> Left ControlNotControllable

-- | Pause intake atomically with lifecycle validation and visible intent.
pauseProcessorIO :: Master -> ProcessorId -> IO ControlOutcome
pauseProcessorIO master pid = do
  now <- getCurrentTime
  atomically $
    controllable master pid >>= \case
      Left outcome -> pure outcome
      Right entry -> case entry.pause of
        Nothing -> pure ControlNotControllable
        Just handle -> do
          changed <- requestPauseSTM handle now
          pausedAt <- readTVar handle.pauseState
          case pausedAt of
            Nothing -> retry -- cannot occur in this transaction
            Just since -> do
              Metrics.markPausedSTM entry.metrics since
              pure $ (if changed then ControlApplied else ControlAlreadyInState) (IntakePaused since)

-- | Resume only live non-draining processors; terminal state is retained.
resumeProcessorIO :: Master -> ProcessorId -> IO ControlOutcome
resumeProcessorIO master pid =
  atomically $
    controllable master pid >>= \case
      Left outcome -> pure outcome
      Right entry -> case entry.pause of
        Nothing -> pure ControlNotControllable
        Just handle -> do
          changed <- requestResumeSTM handle
          Metrics.markResumedSTM entry.metrics
          pure $ (if changed then ControlApplied else ControlAlreadyInState) IntakeRunning

isProcessorPausedIO :: Master -> ProcessorId -> IO (Maybe Bool)
isProcessorPausedIO master pid =
  atomically $
    controllable master pid >>= \case
      Left _ -> pure Nothing
      Right entry -> case entry.pause of
        Nothing -> pure Nothing
        Just handle -> Just . maybe False (const True) <$> readTVar handle.pauseState

pauseProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ControlOutcome
pauseProcessor master = liftIO . pauseProcessorIO master

resumeProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ControlOutcome
resumeProcessor master = liftIO . resumeProcessorIO master

isProcessorPaused :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe Bool)
isProcessorPaused master = liftIO . isProcessorPausedIO master

-- | Shutdown owns admission from this transaction onward. No later control can
-- close a gate again while adapters are shutting down.
drainAndResume :: (IOE :> es) => Master -> Eff es ()
drainAndResume master = liftIO $ atomically $ do
  registry <- readTVar master.state.registry
  forM_ (Map.elems registry.liveMetrics) $ \entry -> do
    forM_ entry.pause $ \handle -> void (requestResumeSTM handle)
    Metrics.markResumedSTM entry.metrics
  writeTVar
    master.state.registry
    registry
      { draining = True,
        lifecycles = Map.map (\case LifecycleRunning -> LifecycleDraining; other -> other) registry.lifecycles
      }
