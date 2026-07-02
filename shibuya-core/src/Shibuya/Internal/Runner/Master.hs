-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Master process - central coordinator for queue processors.
-- Provides supervision, metrics collection, and control API.
--
-- Architecture:
-- - Master is an NQE Process that handles control messages
-- - Holds a Supervisor for managing child processors
-- - Maintains TVar MetricsMap for O(1) metrics access
-- - Processors register their metrics TVars with the Master
module Shibuya.Internal.Runner.Master
  ( -- * Master Handle
    Master (..),
    MasterState (..),

    -- * Control Messages
    MasterMessage (..),

    -- * Starting the Master
    startMaster,
    stopMaster,

    -- * Introspection
    getAllMetrics,
    getAllMetricsIO,
    getProcessorMetrics,
    getProcessorMetricsIO,

    -- * Processor Management
    registerProcessor,
    unregisterProcessor,
  )
where

import Control.Concurrent.NQE.Process
  ( Inbox,
    Listen,
    Process (..),
    newInbox,
    receive,
  )
import Control.Concurrent.NQE.Supervisor (Strategy (..), Supervisor)
import Control.Concurrent.NQE.Supervisor qualified as Supervisor
import Control.Concurrent.STM
  ( TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
  )
import Control.Monad (forever)
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
import Shibuya.Prelude
import UnliftIO (Async, async, cancel, link)

-- | Messages for the master process.
data MasterMessage
  = -- | Register a processor's metrics handle
    RegisterProcessor !ProcessorId !MetricsHandle !(Listen ())
  | -- | Unregister a processor
    UnregisterProcessor !ProcessorId !(Listen ())
  | -- | Shutdown all processors
    Shutdown !(Listen ())

-- | Master state held in TVars.
data MasterState = MasterState
  { -- | Map of processor IDs to their metrics handles
    metrics :: !(TVar (Map ProcessorId MetricsHandle)),
    -- | The supervisor managing child processors
    supervisor :: !Supervisor,
    -- | Whether child failures should be linked into the spawning thread.
    -- Derived from the supervision strategy: True for KillAll/IgnoreGraceful
    -- (failure must reach the application), False for IgnoreAll/Notify.
    propagateFailures :: !Bool
  }
  deriving (Generic)

-- | Master handle - provides access to the master process.
data Master = Master
  { -- | The async handle for the master
    handle :: !(Async ()),
    -- | Direct access to master state
    state :: !MasterState,
    -- | Inbox for sending messages
    inbox :: !(Inbox MasterMessage)
  }
  deriving (Generic)

-- | Start the master process.
-- Returns a handle for interacting with the master.
-- The caller is responsible for calling stopMaster when done.
startMaster :: (IOE :> es) => Strategy -> Eff es Master
startMaster strategy = liftIO $ do
  -- Create supervisor
  sup <- Supervisor.supervisor strategy

  metricsMapVar <- newTVarIO Map.empty
  let propagate = case strategy of
        KillAll -> True
        IgnoreGraceful -> True
        IgnoreAll -> False
        Notify _ -> False
      masterState = MasterState metricsMapVar sup propagate

  masterInbox <- newInbox

  -- Start master loop
  masterHandle <- async $ masterLoop masterState masterInbox
  link masterHandle

  pure
    Master
      { handle = masterHandle,
        state = masterState,
        inbox = masterInbox
      }

-- | Stop the master and all child processors.
-- Cancels the supervisor first (which cancels all children via NQE's stopAll),
-- then cancels the master message loop.
stopMaster :: (IOE :> es) => Master -> Eff es ()
stopMaster master = liftIO $ do
  -- Cancel the supervisor first - this triggers NQE's stopAll which cancels all children
  cancel (getProcessAsync master.state.supervisor)
  -- Then cancel the master message loop
  cancel master.handle

-- | The master process main loop.
masterLoop :: MasterState -> Inbox MasterMessage -> IO ()
masterLoop state inbox = forever $ do
  msg <- receive inbox
  handleMessage state msg

-- | Handle a single master message.
handleMessage :: MasterState -> MasterMessage -> IO ()
handleMessage state msg = case msg of
  RegisterProcessor pid metricsHandle respond -> do
    atomically $ do
      modifyTVar' state.metrics $ Map.insert pid metricsHandle
    atomically $ respond ()
  UnregisterProcessor pid respond -> do
    atomically $ do
      modifyTVar' state.metrics $ Map.delete pid
    atomically $ respond ()
  Shutdown respond -> do
    -- Clear all processors
    atomically $ modifyTVar' state.metrics (const Map.empty)
    atomically $ respond ()

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

-- | Register a processor with the master.
-- The processor should call this with its metrics handle.
registerProcessor :: (IOE :> es) => Master -> ProcessorId -> MetricsHandle -> Eff es ()
registerProcessor master pid metricsHandle =
  liftIO $ atomically $ modifyTVar' master.state.metrics $ Map.insert pid metricsHandle

-- | Unregister a processor from the master.
unregisterProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
unregisterProcessor master pid =
  liftIO $ atomically $ modifyTVar' master.state.metrics $ Map.delete pid
