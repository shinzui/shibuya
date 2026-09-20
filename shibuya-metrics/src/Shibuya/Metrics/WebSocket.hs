-- | WebSocket endpoint for real-time metrics updates.
module Shibuya.Metrics.WebSocket
  ( websocketApp,
    WebSocketState (..),
    newWebSocketState,
    shutdownWebSockets,
  )
where

import Control.Concurrent.Async (race_)
import Control.Concurrent.STM
  ( STM,
    TVar,
    atomically,
    check,
    modifyTVar',
    newTVarIO,
    orElse,
    readTVar,
    readTVarIO,
    registerDelay,
    writeTVar,
  )
import Control.Exception (catch, finally, mask, throwIO)
import Control.Monad (forever, when)
import Data.Aeson (decode, encode)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Network.WebSockets qualified as WS
import Shibuya.App (Master, getAllMetricsIO)
import Shibuya.Core.Metrics (MetricsMap, ProcessorId (..), ProcessorMetrics)
import Shibuya.Core.Types (MessageId (..))
import Shibuya.Internal.Runner.Master
  ( ProcessorLifecycle (..),
    getLifecycleSnapshotIO,
  )
import Shibuya.Metrics.Config (MetricsServerConfig (..))
import Shibuya.Metrics.Types
  ( ClientMessage (..),
    ProcessorTerminalStatus (..),
    ServerMessage (..),
  )

--------------------------------------------------------------------------------
-- WebSocket State
--------------------------------------------------------------------------------

-- | Shared state for WebSocket connections.
data WebSocketState = WebSocketState
  { -- | Current number of connections
    connectionCount :: !(TVar Int),
    -- | Maximum allowed connections
    maxConnections :: !Int,
    -- | Whether server shutdown has begun
    shutdownRequested :: !(TVar Bool)
  }

-- | Create new WebSocket state.
newWebSocketState :: Int -> IO WebSocketState
newWebSocketState maxConns = do
  countVar <- newTVarIO 0
  shutdownVar <- newTVarIO False
  pure
    WebSocketState
      { connectionCount = countVar,
        maxConnections = maxConns,
        shutdownRequested = shutdownVar
      }

-- | Ask every active connection to send 'Goodbye' and finish.
shutdownWebSockets :: WebSocketState -> IO ()
shutdownWebSockets wsState =
  atomically $ writeTVar wsState.shutdownRequested True

data AcquireResult
  = Acquired
  | AtCapacity
  | ServerShuttingDown

-- | Try to acquire a connection slot.
acquireConnection :: WebSocketState -> STM AcquireResult
acquireConnection wsState = do
  shuttingDown <- readTVar wsState.shutdownRequested
  count <- readTVar wsState.connectionCount
  if shuttingDown
    then pure ServerShuttingDown
    else
      if count >= wsState.maxConnections
        then pure AtCapacity
        else do
          writeTVar wsState.connectionCount (count + 1)
          pure Acquired

-- | Release a connection slot.
releaseConnection :: WebSocketState -> STM ()
releaseConnection wsState =
  modifyTVar' wsState.connectionCount (\c -> max 0 (c - 1))

--------------------------------------------------------------------------------
-- Connection State
--------------------------------------------------------------------------------

-- | State for a single WebSocket connection.
data ConnectionState = ConnectionState
  { -- | Processor selection, including exclusions from subscribe-all
    subscriptions :: !(TVar Subscription),
    -- | Last sent metrics for delta detection
    lastMetrics :: !(TVar MetricsMap)
  }

data Subscription
  = AllProcessors !(Set ProcessorId)
  | SelectedProcessors !(Set ProcessorId)

-- | Create new connection state.
newConnectionState :: IO ConnectionState
newConnectionState = do
  subsVar <- newTVarIO $ AllProcessors Set.empty
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
websocketApp config master wsState pending =
  mask $ \restore -> do
    outcome <- atomically $ acquireConnection wsState
    case outcome of
      AtCapacity -> restore $ WS.rejectRequest pending "Too many connections"
      ServerShuttingDown -> restore $ WS.rejectRequest pending "Server shutting down"
      Acquired ->
        restore (serveConnection config master wsState pending `catch` normalPeerClosure)
          `finally` atomically (releaseConnection wsState)

normalPeerClosure :: WS.ConnectionException -> IO ()
normalPeerClosure = \case
  WS.ConnectionClosed -> pure ()
  WS.CloseRequest _ _ -> pure ()
  unexpected -> throwIO unexpected

serveConnection :: MetricsServerConfig -> Master -> WebSocketState -> WS.PendingConnection -> IO ()
serveConnection config master wsState pending = do
  conn <- WS.acceptRequest pending
  WS.withPingThread conn 30 (pure ()) $ do
    connState <- newConnectionState
    metrics <- getAllMetricsIO master
    WS.sendTextData conn $ encode $ MetricsSnapshot metrics
    atomically $ writeTVar connState.lastMetrics metrics
    race_
      (receiveLoop master connState conn)
      (pushLoop config master wsState connState conn)

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
    atomically $ writeTVar connState.subscriptions $ AllProcessors Set.empty
    -- Send snapshot of all metrics
    metrics <- getAllMetricsIO master
    WS.sendTextData conn $ encode $ MetricsSnapshot metrics
    atomically $ writeTVar connState.lastMetrics metrics
  Subscribe pids -> do
    subscription <- atomically $ do
      current <- readTVar connState.subscriptions
      let newSubs = case current of
            AllProcessors _ -> SelectedProcessors $ Set.fromList pids
            SelectedProcessors existing -> SelectedProcessors $ existing <> Set.fromList pids
      writeTVar connState.subscriptions newSubs
      pure newSubs
    allMetrics <- getAllMetricsIO master
    let filtered = filterMetrics subscription allMetrics
    WS.sendTextData conn $ encode $ MetricsSnapshot filtered
    atomically $ writeTVar connState.lastMetrics filtered
  Unsubscribe pids -> do
    atomically $ do
      current <- readTVar connState.subscriptions
      let removed = Set.fromList pids
          newSubs = case current of
            AllProcessors excluded -> AllProcessors $ excluded <> removed
            SelectedProcessors existing -> SelectedProcessors $ Set.difference existing removed
      writeTVar connState.subscriptions newSubs
  Ping ->
    WS.sendTextData conn $ encode Pong

--------------------------------------------------------------------------------
-- Push Loop
--------------------------------------------------------------------------------

-- | Push metrics updates to client at configured interval.
pushLoop ::
  MetricsServerConfig ->
  Master ->
  WebSocketState ->
  ConnectionState ->
  WS.Connection ->
  IO ()
pushLoop config master wsState connState conn = loop
  where
    loop = do
      shuttingDown <- waitForPushOrShutdown config.wsPushIntervalUs wsState
      if shuttingDown
        then WS.sendTextData conn $ encode Goodbye
        else pushUpdates master connState conn >> loop

waitForPushOrShutdown :: Int -> WebSocketState -> IO Bool
waitForPushOrShutdown intervalUs wsState = do
  intervalElapsed <- registerDelay intervalUs
  atomically $
    (readTVar wsState.shutdownRequested >>= \requested -> check requested >> pure True)
      `orElse` (readTVar intervalElapsed >>= \elapsed -> check elapsed >> pure False)

pushUpdates :: Master -> ConnectionState -> WS.Connection -> IO ()
pushUpdates master connState conn = do
  currentMetrics <- getAllMetricsIO master
  lifecycle <- getLifecycleSnapshotIO master
  subscription <- readTVarIO connState.subscriptions
  lastSent <- readTVarIO connState.lastMetrics
  let filteredMetrics = filterMetrics subscription currentMetrics
  _ <- Map.traverseWithKey (sendIfChanged lastSent conn) filteredMetrics
  let removed = Map.keysSet lastSent `Set.difference` Map.keysSet currentMetrics
  mapM_ (sendTerminal lifecycle conn) $ Set.toList removed
  atomically $ writeTVar connState.lastMetrics filteredMetrics

filterMetrics :: Subscription -> MetricsMap -> MetricsMap
filterMetrics subscription =
  Map.filterWithKey $ \pid _ -> case subscription of
    AllProcessors excluded -> Set.notMember pid excluded
    SelectedProcessors selected -> Set.member pid selected

sendTerminal :: Map.Map ProcessorId ProcessorLifecycle -> WS.Connection -> ProcessorId -> IO ()
sendTerminal lifecycle conn pid =
  case Map.lookup pid lifecycle >>= terminalStatus of
    Nothing -> pure ()
    Just status -> WS.sendTextData conn $ encode $ ProcessorTerminal pid status

terminalStatus :: ProcessorLifecycle -> Maybe ProcessorTerminalStatus
terminalStatus = \case
  LifecycleStopped -> Just TerminalStopped
  LifecycleFailed failure messageId ->
    Just $ TerminalFailed failure (messageIdText <$> messageId)
  LifecycleRunning -> Nothing
  LifecycleDraining -> Nothing

messageIdText :: MessageId -> Text
messageIdText (MessageId value) = value

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
