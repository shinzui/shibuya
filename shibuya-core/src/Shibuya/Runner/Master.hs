-- | Master process - central coordinator for queue processors.
-- Provides supervision, metrics collection, and control API.
--
-- Architecture:
-- - Master is an NQE Process that handles control messages
-- - Holds a Supervisor for managing child processors
-- - Maintains TVar MetricsMap for O(1) metrics access
-- - Processors register their metrics TVars with the Master
module Shibuya.Runner.Master
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
    newInbox,
    query,
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
import Shibuya.Prelude
import Shibuya.Runner.Metrics
  ( MetricsMap,
    ProcessorId,
    ProcessorMetrics,
  )
import UnliftIO (Async, async, cancel, link)

-- | Messages for the master process.
data MasterMessage
  = -- | Get metrics for all processors
    GetAllMetrics !(Listen MetricsMap)
  | -- | Get metrics for a specific processor
    GetProcessorMetrics ProcessorId !(Listen (Maybe ProcessorMetrics))
  | -- | Register a processor's metrics TVar
    RegisterProcessor !ProcessorId !(TVar ProcessorMetrics) !(Listen ())
  | -- | Unregister a processor
    UnregisterProcessor !ProcessorId !(Listen ())
  | -- | Shutdown all processors
    Shutdown !(Listen ())

-- | Master state held in TVars.
data MasterState = MasterState
  { -- | Map of processor IDs to their metrics TVars
    metrics :: !(TVar (Map ProcessorId (TVar ProcessorMetrics))),
    -- | The supervisor managing child processors
    supervisor :: !Supervisor
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
  let masterState = MasterState metricsMapVar sup

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
stopMaster :: (IOE :> es) => Master -> Eff es ()
stopMaster master = liftIO $ do
  cancel (master ^. #handle)

-- | The master process main loop.
masterLoop :: MasterState -> Inbox MasterMessage -> IO ()
masterLoop state inbox = forever $ do
  msg <- receive inbox
  handleMessage state msg

-- | Handle a single master message.
handleMessage :: MasterState -> MasterMessage -> IO ()
handleMessage state msg = case msg of
  GetAllMetrics respond -> do
    -- Read all metrics from their TVars
    metricsMap <- atomically $ do
      tvarsMap <- readTVar state.metrics
      traverse readTVar tvarsMap
    atomically $ respond metricsMap
  GetProcessorMetrics pid respond -> do
    result <- atomically $ do
      tvarsMap <- readTVar state.metrics
      case Map.lookup pid tvarsMap of
        Nothing -> pure Nothing
        Just tvar -> Just <$> readTVar tvar
    atomically $ respond result
  RegisterProcessor pid metricsTVar respond -> do
    atomically $ do
      modifyTVar' state.metrics $ Map.insert pid metricsTVar
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
getAllMetrics master =
  liftIO $
    GetAllMetrics `query` master.inbox

-- | Get metrics for all processors (IO version for web servers).
getAllMetricsIO :: Master -> IO MetricsMap
getAllMetricsIO master = GetAllMetrics `query` master.inbox

-- | Get metrics for a specific processor.
getProcessorMetrics :: (IOE :> es) => Master -> ProcessorId -> Eff es (Maybe ProcessorMetrics)
getProcessorMetrics master pid =
  liftIO $
    GetProcessorMetrics pid `query` master.inbox

-- | Get metrics for a specific processor (IO version for web servers).
getProcessorMetricsIO :: Master -> ProcessorId -> IO (Maybe ProcessorMetrics)
getProcessorMetricsIO master pid = GetProcessorMetrics pid `query` master.inbox

-- | Register a processor with the master.
-- The processor should call this with its metrics TVar.
registerProcessor :: (IOE :> es) => Master -> ProcessorId -> TVar ProcessorMetrics -> Eff es ()
registerProcessor master pid metricsTVar =
  liftIO $
    RegisterProcessor pid metricsTVar `query` master.inbox

-- | Unregister a processor from the master.
unregisterProcessor :: (IOE :> es) => Master -> ProcessorId -> Eff es ()
unregisterProcessor master pid =
  liftIO $
    UnregisterProcessor pid `query` master.inbox
