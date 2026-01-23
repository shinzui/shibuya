-- | WebSocket endpoint for real-time metrics updates.
module Shibuya.Metrics.WebSocket
  ( websocketApp,
    WebSocketState (..),
    newWebSocketState,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel, link)
import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    writeTVar,
  )
import Control.Exception (finally)
import Control.Monad (forever, when)
import Data.Aeson (decode, encode)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Network.WebSockets qualified as WS
import Shibuya.Metrics.Config (MetricsServerConfig (..))
import Shibuya.Metrics.Types (ClientMessage (..), ServerMessage (..))
import Shibuya.Runner.Master (Master, getAllMetricsIO)
import Shibuya.Runner.Metrics (MetricsMap, ProcessorId (..), ProcessorMetrics)

--------------------------------------------------------------------------------
-- WebSocket State
--------------------------------------------------------------------------------

-- | Shared state for WebSocket connections.
data WebSocketState = WebSocketState
  { -- | Current number of connections
    connectionCount :: !(TVar Int),
    -- | Maximum allowed connections
    maxConnections :: !Int
  }

-- | Create new WebSocket state.
newWebSocketState :: Int -> IO WebSocketState
newWebSocketState maxConns = do
  countVar <- newTVarIO 0
  pure
    WebSocketState
      { connectionCount = countVar,
        maxConnections = maxConns
      }

-- | Try to acquire a connection slot. Returns True if successful.
acquireConnection :: WebSocketState -> STM Bool
acquireConnection wsState = do
  count <- readTVar wsState.connectionCount
  if count < wsState.maxConnections
    then do
      writeTVar wsState.connectionCount (count + 1)
      pure True
    else pure False

-- | Release a connection slot.
releaseConnection :: WebSocketState -> STM ()
releaseConnection wsState =
  modifyTVar' wsState.connectionCount (\c -> max 0 (c - 1))

--------------------------------------------------------------------------------
-- Connection State
--------------------------------------------------------------------------------

-- | State for a single WebSocket connection.
data ConnectionState = ConnectionState
  { -- | Subscribed processors (Nothing = all)
    subscriptions :: !(TVar (Maybe (Set ProcessorId))),
    -- | Last sent metrics for delta detection
    lastMetrics :: !(TVar MetricsMap)
  }

-- | Create new connection state.
newConnectionState :: IO ConnectionState
newConnectionState = do
  subsVar <- newTVarIO Nothing -- Start subscribed to all
  lastVar <- newTVarIO Map.empty
  pure
    ConnectionState
      { subscriptions = subsVar,
        lastMetrics = lastVar
      }

--------------------------------------------------------------------------------
-- WebSocket Application
--------------------------------------------------------------------------------

-- | WebSocket server application.
websocketApp ::
  MetricsServerConfig ->
  Master ->
  WebSocketState ->
  WS.ServerApp
websocketApp config master wsState pending = do
  -- Try to acquire a connection slot
  acquired <- atomically $ acquireConnection wsState
  if not acquired
    then WS.rejectRequest pending "Too many connections"
    else do
      conn <- WS.acceptRequest pending
      -- Set up connection with ping/pong for keepalive
      WS.withPingThread conn 30 (pure ()) $ do
        connState <- newConnectionState
        -- Send initial snapshot
        metrics <- getAllMetricsIO master
        WS.sendTextData conn $ encode $ MetricsSnapshot metrics
        atomically $ writeTVar connState.lastMetrics metrics
        -- Run receive and push loops concurrently
        pushThread <- async $ pushLoop config master connState conn
        link pushThread
        finally
          (receiveLoop master connState conn)
          ( do
              cancel pushThread
              WS.sendTextData conn $ encode Goodbye
              atomically $ releaseConnection wsState
          )

--------------------------------------------------------------------------------
-- Receive Loop
--------------------------------------------------------------------------------

-- | Handle incoming messages from client.
receiveLoop :: Master -> ConnectionState -> WS.Connection -> IO ()
receiveLoop master connState conn = forever $ do
  msg <- WS.receiveData conn
  case decode msg of
    Nothing -> pure () -- Ignore invalid messages
    Just clientMsg -> handleClientMessage master connState conn clientMsg

-- | Handle a client message.
handleClientMessage ::
  Master ->
  ConnectionState ->
  WS.Connection ->
  ClientMessage ->
  IO ()
handleClientMessage master connState conn = \case
  SubscribeAll -> do
    atomically $ writeTVar connState.subscriptions Nothing
    -- Send snapshot of all metrics
    metrics <- getAllMetricsIO master
    WS.sendTextData conn $ encode $ MetricsSnapshot metrics
    atomically $ writeTVar connState.lastMetrics metrics
  Subscribe pids -> do
    atomically $ do
      current <- readTVar connState.subscriptions
      let newSubs = case current of
            Nothing -> Just $ Set.fromList pids
            Just existing -> Just $ existing <> Set.fromList pids
      writeTVar connState.subscriptions newSubs
    -- Send snapshot of subscribed processors
    allMetrics <- getAllMetricsIO master
    let filtered = Map.filterWithKey (\pid _ -> pid `elem` pids) allMetrics
    WS.sendTextData conn $ encode $ MetricsSnapshot filtered
  Unsubscribe pids -> do
    atomically $ do
      current <- readTVar connState.subscriptions
      case current of
        Nothing -> do
          -- Was subscribed to all, now remove these
          -- We need all processor IDs to calculate the new set
          pure () -- Keep as Nothing, will filter in push
        Just existing ->
          writeTVar connState.subscriptions $
            Just $
              Set.difference existing (Set.fromList pids)
  Ping ->
    WS.sendTextData conn $ encode Pong

--------------------------------------------------------------------------------
-- Push Loop
--------------------------------------------------------------------------------

-- | Push metrics updates to client at configured interval.
pushLoop ::
  MetricsServerConfig ->
  Master ->
  ConnectionState ->
  WS.Connection ->
  IO ()
pushLoop config master connState conn = forever $ do
  threadDelay config.wsPushIntervalUs
  -- Get current metrics
  currentMetrics <- getAllMetricsIO master
  -- Get subscription filter
  mSubs <- atomically $ readTVar connState.subscriptions
  -- Get last sent metrics
  lastSent <- atomically $ readTVar connState.lastMetrics
  -- Filter metrics based on subscriptions
  let filteredMetrics = case mSubs of
        Nothing -> currentMetrics
        Just subs -> Map.filterWithKey (\pid _ -> Set.member pid subs) currentMetrics
  -- Send updates for changed processors
  Map.traverseWithKey (sendIfChanged lastSent conn) filteredMetrics
  -- Update last sent
  atomically $ writeTVar connState.lastMetrics filteredMetrics

-- | Send update if metrics have changed.
sendIfChanged ::
  MetricsMap ->
  WS.Connection ->
  ProcessorId ->
  ProcessorMetrics ->
  IO ()
sendIfChanged lastSent conn pid metrics = do
  let changed = case Map.lookup pid lastSent of
        Nothing -> True
        Just old -> old /= metrics
  when changed $
    WS.sendTextData conn $
      encode $
        ProcessorUpdate pid metrics
