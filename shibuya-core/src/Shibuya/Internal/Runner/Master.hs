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
import UnliftIO (async, cancel)

-- | Master state held in TVars.
data MasterState = MasterState
  { -- | Map of processor IDs to their metrics handles
    metrics :: !(TVar (Map ProcessorId MetricsHandle)),
    -- | Bounded lifecycle state for every configured processor. Entries remain
    -- after live metrics unregister so terminal failures stay observable.
    lifecycle :: !(TVar LifecycleSnapshot),
    -- | The supervisor managing child processors
    supervisor :: !Supervisor,
    -- | Whether child failures should be linked into the spawning thread.
    -- Derived from the supervision strategy: True for KillAll/IgnoreGraceful
    -- (failure must reach the application), False for IgnoreAll/Notify.
    propagateFailures :: !Bool
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
  supAsync <- async (Supervisor.supervisorProcess strategy inbox)
  let finishAcquisition = do
        let sup = Process supAsync mailbox
        metricsMapVar <- newTVarIO Map.empty
        lifecycleVar <- newTVarIO Map.empty
        let propagate = case strategy of
              KillAll -> True
              IgnoreGraceful -> True
              IgnoreAll -> False
              Notify _ -> False
        pure Master {state = MasterState metricsMapVar lifecycleVar sup propagate}
  finishAcquisition `Exception.onException` cancel supAsync

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
  handlesMap <- atomically $ readTVar master.state.metrics
  traverse sampleMetrics handlesMap

-- | Get metrics for a specific processor.
getProcessorMetrics :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
getProcessorMetrics master = liftIO . getProcessorMetricsIO master

-- | Get metrics for a specific processor (IO version for web servers).
getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
getProcessorMetricsIO master pid = do
  handlesMap <- atomically $ readTVar master.state.metrics
  traverse sampleMetrics (Map.lookup pid handlesMap)

-- | Read the retained processor lifecycle snapshot.
getLifecycleSnapshot :: (IOE :> es) => Master -> Eff es LifecycleSnapshot
getLifecycleSnapshot = liftIO . getLifecycleSnapshotIO

-- | IO variant for metrics and health integrations.
getLifecycleSnapshotIO :: Master -> IO LifecycleSnapshot
getLifecycleSnapshotIO master = atomically $ readTVar master.state.lifecycle

-- | Register a processor with the master.
-- The processor should call this with its metrics handle.
registerProcessor :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Eff es ()
registerProcessor master pid metricsHandle =
  liftIO $
    atomically $ do
      modifyTVar' master.state.metrics $ Map.insert pid metricsHandle
      modifyTVar' master.state.lifecycle $ Map.insert pid LifecycleRunning

-- | Unregister a processor from the master.
unregisterProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
unregisterProcessor master pid =
  liftIO $ atomically $ modifyTVar' master.state.metrics $ Map.delete pid

markProcessorDraining :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
markProcessorDraining master pid =
  liftIO $
    atomically $
      modifyTVar' master.state.lifecycle $
        Map.adjust
          (\case LifecycleRunning -> LifecycleDraining; terminal -> terminal)
          pid

markProcessorStopped :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
markProcessorStopped master pid =
  liftIO $
    atomically $
      modifyTVar' master.state.lifecycle $
        Map.adjust
          (\case LifecycleFailed failure messageId -> LifecycleFailed failure messageId; _ -> LifecycleStopped)
          pid

markProcessorFailed :: (IOE :> es) => Master -> ProcessorId -> Text -> Maybe MessageId -> Eff es ()
markProcessorFailed master pid failure messageId =
  liftIO $
    atomically $
      modifyTVar' master.state.lifecycle $
        Map.insert pid (LifecycleFailed failure messageId)
