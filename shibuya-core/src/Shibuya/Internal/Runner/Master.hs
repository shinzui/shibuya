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
    ProcessorLifecycle (..),
    LifecycleSnapshot,
    getLifecycleSnapshot,
    getLifecycleSnapshotIO,

    -- * Processor Management
    registerProcessor,
    unregisterProcessor,
    markProcessorDraining,
    markProcessorStopped,
    markProcessorFailed,
  )
where

import Control.Concurrent.NQE.Process (Process (..), newMailbox)
import Control.Concurrent.NQE.Supervisor (Strategy (..), Supervisor)
import Control.Concurrent.NQE.Supervisor qualified as Supervisor
import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
  )
import Control.Exception qualified as Exception
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
import Shibuya.Core.Types (MessageId)
import Shibuya.Prelude
import UnliftIO (asyncWithUnmask, cancel)

-- | Master state held in TVars.
data MasterState = MasterState
  { -- | Live metrics and retained lifecycle state share one STM ownership
    -- cell. Registration can therefore publish both atomically without adding
    -- another per-master TVar to the startup path.
    registry :: !(TVar MasterRegistry),
    -- | The supervisor managing child processors
    supervisor :: !Supervisor,
    -- | Whether child failures should be linked into the spawning thread.
    -- Derived from the supervision strategy: True for KillAll/IgnoreGraceful
    -- (failure must reach the application), False for IgnoreAll/Notify.
    propagateFailures :: !Bool
  }
  deriving (Generic)

data MasterRegistry = MasterRegistry
  { liveMetrics :: !(Map ProcessorId MetricsHandle),
    lifecycles :: !LifecycleSnapshot
  }
  deriving (Generic)

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
  registryVar <- newTVarIO $ MasterRegistry Map.empty Map.empty
  let propagate = case strategy of
        KillAll -> True
        IgnoreGraceful -> True
        IgnoreAll -> False
        Notify _ -> False
  pure Master {state = MasterState registryVar sup propagate}

-- | Stop the master and all child processors.
-- Cancels the supervisor, which cancels all children via NQE's stopAll.
stopMaster :: (IOE :> es) => Master -> Eff es ()
stopMaster master = liftIO $ cancel (getProcessAsync master.state.supervisor)

-- | Get metrics for all processors.
getAllMetrics :: (IOE :> es) => Master -> Eff es MetricsMap
getAllMetrics = liftIO . getAllMetricsIO

-- | Get metrics for all processors (IO version for web servers).
getAllMetricsIO :: Master -> IO MetricsMap
getAllMetricsIO master = do
  registry <- atomically $ readTVar master.state.registry
  traverse sampleMetrics registry.liveMetrics

-- | Get metrics for a specific processor.
getProcessorMetrics :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
getProcessorMetrics master = liftIO . getProcessorMetricsIO master

-- | Get metrics for a specific processor (IO version for web servers).
getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
getProcessorMetricsIO master pid = do
  registry <- atomically $ readTVar master.state.registry
  traverse sampleMetrics (Map.lookup pid registry.liveMetrics)

-- | Read the retained processor lifecycle snapshot.
getLifecycleSnapshot :: (IOE :> es) => Master -> Eff es LifecycleSnapshot
getLifecycleSnapshot = liftIO . getLifecycleSnapshotIO

-- | IO variant for metrics and health integrations.
getLifecycleSnapshotIO :: Master -> IO LifecycleSnapshot
getLifecycleSnapshotIO master = (.lifecycles) <$> atomically (readTVar master.state.registry)

-- | Register a processor with the master.
-- The processor should call this with its metrics handle.
registerProcessor :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Eff es ()
registerProcessor master pid metricsHandle =
  liftIO $
    atomically $
      modifyTVar' master.state.registry $ \registry ->
        registry
          { liveMetrics = Map.insert pid metricsHandle registry.liveMetrics,
            lifecycles = Map.insert pid LifecycleRunning registry.lifecycles
          }

-- | Unregister a processor from the master.
unregisterProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
unregisterProcessor master pid =
  liftIO $
    atomically $
      modifyTVar' master.state.registry $ \registry ->
        registry {liveMetrics = Map.delete pid registry.liveMetrics}

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
markProcessorStopped master pid =
  liftIO $
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
  liftIO $
    atomically $
      modifyTVar' master.state.registry $ \registry ->
        registry
          { lifecycles = Map.insert pid (LifecycleFailed failure messageId) registry.lifecycles
          }
