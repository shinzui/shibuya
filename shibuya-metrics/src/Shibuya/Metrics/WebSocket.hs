-- | Real-time metrics with independent production and one bounded application writer.
module Shibuya.Metrics.WebSocket
  ( websocketApp,
    WebSocketState (..),
    newWebSocketState,
    shutdownWebSockets,
    WebSocketHooks (..),
    defaultWebSocketHooks,
    websocketAppWithHooks,
  )
where

import Control.Concurrent.Async (race_)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
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
    retry,
    writeTVar,
  )
import Control.Exception (catch, evaluate, finally, mask, throwIO)
import Control.Monad (forever, unless, when)
import Data.Aeson (eitherDecode, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word16, Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Network.WebSockets qualified as WS
import Shibuya.App (Master, getAllMetricsIO)
import Shibuya.Core.Metrics (MetricsMap, ProcessorId (..))
import Shibuya.Core.Types (MessageId (..))
import Shibuya.Internal.Runner.Master (ProcessorLifecycle (..), getLifecycleSnapshotIO)
import Shibuya.Metrics.Config (MetricsServerConfig (..))
import Shibuya.Metrics.Outbound qualified as Out
import Shibuya.Metrics.Types (ClientMessage (..), ProcessorTerminalStatus (..), ServerMessage (..))
import System.Timeout (timeout)

-- | Shared connection accounting and idempotent shutdown signal.
data WebSocketState = WebSocketState
  {connectionCount :: !(TVar Int), maxConnections :: !Int, shutdownRequested :: !(TVar Bool)}

newWebSocketState :: Int -> IO WebSocketState
newWebSocketState maxConns = WebSocketState <$> newTVarIO 0 <*> pure maxConns <*> newTVarIO False

-- | Stop admission and wake every producer to request an orderly, bounded flush.
shutdownWebSockets :: WebSocketState -> IO ()
shutdownWebSockets state = atomically $ writeTVar state.shutdownRequested True

data AcquireResult = Acquired | AtCapacity | ServerShuttingDown

acquireConnection :: WebSocketState -> STM AcquireResult
acquireConnection state = do
  stopping <- readTVar state.shutdownRequested
  count <- readTVar state.connectionCount
  if stopping
    then pure ServerShuttingDown
    else
      if count >= state.maxConnections
        then pure AtCapacity
        else writeTVar state.connectionCount (count + 1) >> pure Acquired

releaseConnection :: WebSocketState -> STM ()
releaseConnection state = modifyTVar' state.connectionCount (max 0 . subtract 1)

data Subscription = AllProcessors !(Set ProcessorId) | SelectedProcessors !(Set ProcessorId)

-- The lock covers subscription, sampling, ledger and admission. It never covers
-- socket IO. Only the writer pops the queue; all producers obey the close cell.
data ConnectionState = ConnectionState
  { producerLock :: !(MVar ()),
    subscriptions :: !(TVar Subscription),
    generation :: !(TVar Int),
    lastMetrics :: !(TVar MetricsMap),
    outbound :: !(TVar Out.OutboundQueue),
    resyncPending :: !(TVar Bool),
    closing :: !(TVar (Maybe CloseControl))
  }

data CloseControl = CloseControl !Word16 !Text !Word64

newConnectionState :: IO ConnectionState
newConnectionState =
  ConnectionState
    <$> newMVar ()
    <*> newTVarIO (AllProcessors Set.empty)
    <*> newTVarIO 0
    <*> newTVarIO Map.empty
    <*> newTVarIO Out.empty
    <*> newTVarIO False
    <*> newTVarIO Nothing

-- | Instrumentation for deterministic transport tests and externally mounted
-- servers. Hooks run inside the send deadline. Production uses no-op hooks and
-- an independent interval timer; a custom wait must also observe shutdown.
data WebSocketHooks = WebSocketHooks
  { beforeWrite :: !(BS.ByteString -> IO ()),
    afterReceive :: !(Out.OutboundQueue -> IO ()),
    afterProduce :: !(Out.OutboundQueue -> IO ()),
    waitForPush :: !(Int -> WebSocketState -> IO Bool)
  }

defaultWebSocketHooks :: WebSocketHooks
defaultWebSocketHooks = WebSocketHooks (const $ pure ()) (const $ pure ()) (const $ pure ()) waitForPushOrShutdown

websocketApp :: MetricsServerConfig -> Master -> WebSocketState -> WS.ServerApp
websocketApp = websocketAppWithHooks defaultWebSocketHooks

websocketAppWithHooks :: WebSocketHooks -> MetricsServerConfig -> Master -> WebSocketState -> WS.ServerApp
websocketAppWithHooks hooks config master state pending = mask $ \restore -> do
  outcome <- atomically $ acquireConnection state
  case outcome of
    AtCapacity -> restore $ WS.rejectRequest pending "Too many connections"
    ServerShuttingDown -> restore $ WS.rejectRequest pending "Server shutting down"
    Acquired ->
      restore (serveConnection hooks config master state pending `catch` normalPeerClosure)
        `finally` atomically (releaseConnection state)

normalPeerClosure :: WS.ConnectionException -> IO ()
normalPeerClosure = \case
  WS.ConnectionClosed -> pure ()
  WS.CloseRequest _ _ -> pure ()
  unexpected -> throwIO unexpected

serveConnection :: WebSocketHooks -> MetricsServerConfig -> Master -> WebSocketState -> WS.PendingConnection -> IO ()
serveConnection hooks config master state pending = do
  conn <- WS.acceptRequest pending
  WS.withPingThread conn 30 (pure ()) $ do
    cs <- newConnectionState
    withMVar cs.producerLock $ \() -> subscriptionSnapshot config master cs
    -- Orderly producers wait rather than returning and cancelling queued data.
    -- A peer exception, writer timeout or writer completion cancels and joins both.
    race_
      (writerLoop hooks config cs conn)
      (race_ (receiveLoop hooks config master state cs conn) (pushLoop hooks config master state cs))

limits :: MetricsServerConfig -> Out.Limits
limits config = Out.Limits config.wsMaxQueuedFrames config.wsMaxQueuedBytes

encoded :: Int -> Out.Retention -> ServerMessage -> IO Out.Frame
encoded gen keep message = do
  let bytes = LBS.toStrict $ encode message
  _ <- evaluate $ BS.length bytes
  pure $ Out.frame gen keep bytes

-- Called under the producer lock. Encoding is forced before entering STM.
admit :: MetricsServerConfig -> ConnectionState -> [Out.Frame] -> IO Out.Outcome
admit config cs frames = do
  outcome <- atomically $ do
    stopped <- readTVar cs.closing
    case stopped of
      Just _ -> pure Out.MustClose
      Nothing -> do
        q <- readTVar cs.outbound
        let (result, next) = Out.enqueue (limits config) frames q
        writeTVar cs.outbound next
        when (result == Out.DroppedUpdates) $ writeTVar cs.resyncPending True
        pure result
  when (outcome == Out.MustClose) $ requestClose config cs 1013 "Outbound queue capacity exceeded"
  pure outcome

requestClose :: MetricsServerConfig -> ConnectionState -> Word16 -> Text -> IO ()
requestClose config cs code reason = do
  now <- getMonotonicTimeNSec
  atomically $ do
    current <- readTVar cs.closing
    case current of
      Just _ -> pure ()
      Nothing ->
        writeTVar cs.closing $
          Just $
            CloseControl
              code
              reason
              (now + fromIntegral config.wsSendTimeoutUs * 1_000)

awaitWriter :: IO a
awaitWriter = atomically retry

receiveLoop :: WebSocketHooks -> MetricsServerConfig -> Master -> WebSocketState -> ConnectionState -> WS.Connection -> IO ()
receiveLoop hooks config master state cs conn = forever $ do
  msg <- WS.receiveData conn
  withMVar cs.producerLock $ \() -> do
    stopped <- readTVarIO cs.closing
    case stopped of
      Just _ -> pure ()
      Nothing -> do
        shuttingDown <- readTVarIO state.shutdownRequested
        unless shuttingDown $ case eitherDecode msg of
          Left reason -> do
            gen <- readTVarIO cs.generation
            err <- encoded gen Out.Required $ ServerError "invalid_message" (Text.pack reason)
            _ <- admit config cs [err]
            pure ()
          Right clientMsg -> handleClientMessage config master cs clientMsg
  readTVarIO cs.outbound >>= hooks.afterReceive
  stopped <- readTVarIO cs.closing
  case stopped of Just _ -> awaitWriter; Nothing -> pure ()

handleClientMessage :: MetricsServerConfig -> Master -> ConnectionState -> ClientMessage -> IO ()
handleClientMessage config master cs = \case
  Ping -> do
    gen <- readTVarIO cs.generation
    pong <- encoded gen Out.Ephemeral Pong
    _ <- admit config cs [pong]
    pure ()
  message -> do
    current <- readTVarIO cs.subscriptions
    let next = case message of
          SubscribeAll -> AllProcessors Set.empty
          Subscribe pids -> case current of
            AllProcessors _ -> SelectedProcessors $ Set.fromList pids
            SelectedProcessors existing -> SelectedProcessors $ existing <> Set.fromList pids
          Unsubscribe pids -> case current of
            AllProcessors excluded -> AllProcessors $ excluded <> Set.fromList pids
            SelectedProcessors existing -> SelectedProcessors $ existing `Set.difference` Set.fromList pids
    if subscriptionSize next > config.wsMaxSubscriptions
      then rejectOversizedSubscription config cs
      else do
        atomically $ do
          writeTVar cs.subscriptions next
          modifyTVar' cs.generation (+ 1)
          modifyTVar' cs.outbound Out.discardUpdates
        subscriptionSnapshot config master cs

subscriptionSize :: Subscription -> Int
subscriptionSize = \case
  AllProcessors excluded -> Set.size excluded
  SelectedProcessors selected -> Set.size selected

subscriptionSnapshot :: MetricsServerConfig -> Master -> ConnectionState -> IO ()
subscriptionSnapshot config master cs = do
  subscription <- readTVarIO cs.subscriptions
  metrics <- filterMetrics subscription <$> getAllMetricsIO master
  gen <- readTVarIO cs.generation
  snapshot <- encoded gen Out.Required $ MetricsSnapshot metrics
  result <- admit config cs [snapshot]
  unless (result == Out.MustClose) $ atomically $ do
    writeTVar cs.lastMetrics metrics
    writeTVar cs.resyncPending False

rejectOversizedSubscription :: MetricsServerConfig -> ConnectionState -> IO ()
rejectOversizedSubscription config cs = do
  let reason = "WebSocket processor subscription limit exceeded (maximum " <> Text.pack (show config.wsMaxSubscriptions) <> ")"
  gen <- readTVarIO cs.generation
  err <- encoded gen Out.Required $ ServerError "subscription_limit_exceeded" reason
  -- Set policy close first in the same producer critical section: capacity failure
  -- cannot override 1008. Admission below is atomic with the close signal.
  now <- getMonotonicTimeNSec
  atomically $ do
    q <- readTVar cs.outbound
    let (_, next) = Out.enqueue (limits config) [err] q
    writeTVar cs.outbound next
    writeTVar cs.closing $ Just $ CloseControl 1008 reason (now + fromIntegral config.wsSendTimeoutUs * 1_000)

pushLoop :: WebSocketHooks -> MetricsServerConfig -> Master -> WebSocketState -> ConnectionState -> IO ()
pushLoop hooks config master state cs = loop
  where
    loop = do
      shutdown <- hooks.waitForPush config.wsPushIntervalUs state
      withMVar cs.producerLock $ \() -> do
        stopped <- readTVarIO cs.closing
        case stopped of
          Just _ -> pure ()
          Nothing -> do
            requested <- readTVarIO state.shutdownRequested
            if shutdown || requested then orderlyShutdown else pushUpdates config master cs
      readTVarIO cs.outbound >>= hooks.afterProduce
      stopped <- readTVarIO cs.closing
      case stopped of Just _ -> awaitWriter; Nothing -> loop
    orderlyShutdown = do
      gen <- readTVarIO cs.generation
      goodbye <- encoded gen Out.Required Goodbye
      atomically $ modifyTVar' cs.outbound Out.discardUpdates
      _ <- admit config cs [goodbye]
      requestClose config cs 1000 "Server shutting down"

waitForPushOrShutdown :: Int -> WebSocketState -> IO Bool
waitForPushOrShutdown intervalUs state = do
  elapsed <- registerDelay intervalUs
  atomically $
    (readTVar state.shutdownRequested >>= \requested -> check requested >> pure True)
      `orElse` (readTVar elapsed >>= \ready -> check ready >> pure False)

pushUpdates :: MetricsServerConfig -> Master -> ConnectionState -> IO ()
pushUpdates config master cs = do
  current <- getAllMetricsIO master
  lifecycle <- getLifecycleSnapshotIO master
  subscription <- readTVarIO cs.subscriptions
  previous <- readTVarIO cs.lastMetrics
  resync <- readTVarIO cs.resyncPending
  gen <- readTVarIO cs.generation
  let filtered = filterMetrics subscription current
      removed = Map.keysSet previous `Set.difference` Map.keysSet current
      terminals =
        [ ProcessorTerminal pid status
        | pid <- Set.toList removed,
          Just status <- [Map.lookup pid lifecycle >>= terminalStatus]
        ]
  terminalFrames <- mapM (encoded gen Out.Required) terminals
  if resync
    then do
      atomically $ modifyTVar' cs.outbound Out.discardUpdates
      err <- encoded gen Out.Required $ ServerError "queue_overflow" "Updates dropped; replacing metrics snapshot"
      snapshot <- encoded gen Out.Required $ MetricsSnapshot filtered
      result <- admit config cs (terminalFrames <> [err, snapshot])
      unless (result == Out.MustClose) $ atomically $ do
        writeTVar cs.lastMetrics filtered
        writeTVar cs.resyncPending False
    else do
      -- Required terminal events precede updates and survive eviction.
      result <- admit config cs terminalFrames
      unless (result == Out.MustClose) $ do
        let updates = [ProcessorUpdate pid pm | (pid, pm) <- Map.toList filtered, Map.lookup pid previous /= Just pm]
        frames <- mapM (encoded gen Out.Update) updates
        updateResult <- admit config cs frames
        unless (updateResult == Out.MustClose) $ atomically $ do
          -- Retain the old live comparison ledger after delta loss, but retire
          -- admitted terminals so the recovery tick never repeats them.
          pending <- readTVar cs.resyncPending
          writeTVar cs.lastMetrics $ if pending then Map.withoutKeys previous removed else filtered

writerLoop :: WebSocketHooks -> MetricsServerConfig -> ConnectionState -> WS.Connection -> IO ()
writerLoop hooks config cs conn = loop
  where
    loop = do
      next <- atomically $ do
        q <- readTVar cs.outbound
        case Out.pop q of
          Just (value, rest) -> writeTVar cs.outbound rest >> pure (Left value)
          Nothing -> readTVar cs.closing >>= maybe retry (pure . Right)
      case next of
        Left value -> bounded (hooks.beforeWrite (Out.payload value) >> WS.sendTextData conn (Out.payload value)) >> loop
        Right (CloseControl code reason _) -> bounded $ WS.sendCloseCode conn code reason
    bounded action = do
      now <- getMonotonicTimeNSec
      closing <- readTVarIO cs.closing
      let remaining = case closing of
            Nothing -> config.wsSendTimeoutUs
            Just (CloseControl _ _ deadline) -> if now >= deadline then 0 else fromIntegral ((deadline - now) `div` 1_000)
      result <- timeout (min config.wsSendTimeoutUs remaining) action
      case result of Nothing -> throwIO WS.ConnectionClosed; Just () -> pure ()

filterMetrics :: Subscription -> MetricsMap -> MetricsMap
filterMetrics subscription = Map.filterWithKey $ \pid _ -> case subscription of
  AllProcessors excluded -> Set.notMember pid excluded
  SelectedProcessors selected -> Set.member pid selected

terminalStatus :: ProcessorLifecycle -> Maybe ProcessorTerminalStatus
terminalStatus = \case
  LifecycleStopped -> Just TerminalStopped
  LifecycleFailed failure messageId -> Just $ TerminalFailed failure (messageIdText <$> messageId)
  LifecycleRunning -> Nothing
  LifecycleDraining -> Nothing

messageIdText :: MessageId -> Text
messageIdText (MessageId value) = value
