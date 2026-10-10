module Shibuya.Metrics.WebSocketSpec (spec) where

import Control.Concurrent (MVar, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Concurrent.STM (TQueue, TVar, atomically, check, newTQueueIO, newTVarIO, orElse, readTQueue, readTVar, writeTQueue, writeTVar)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad (replicateM_, when)
import Data.Aeson (Value, eitherDecode, encode, object, (.=))
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Effectful (runEff)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import Shibuya.App (Master, getAllMetricsIO)
import Shibuya.Core.Metrics
  ( MetricsMap,
    ProcessorId (..),
    ProcessorMetrics (..),
    StreamStats (..),
    beginProcessing,
    incrementReceived,
    newMetricsHandleWithClock,
  )
import Shibuya.Internal.Runner.Master (markProcessorFailedIO, registerProcessor, unregisterProcessor)
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Outbound qualified as Out
import Shibuya.Metrics.Server (combinedApp, stopMetricsServer, withMetricsServer)
import Shibuya.Metrics.TestSupport
  ( fixedTime,
    registerIdleProcessor,
    withMaster,
  )
import Shibuya.Metrics.Types
  ( ClientMessage (..),
    ProcessorTerminalStatus (..),
    ServerMessage (..),
  )
import Shibuya.Metrics.WebSocket
  ( WebSocketHooks (..),
    WebSocketState (..),
    defaultWebSocketHooks,
    newWebSocketState,
    shutdownWebSockets,
    websocketAppWithHooks,
  )
import System.Timeout (timeout)
import Test.Hspec
  ( Spec,
    anyException,
    around,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldSatisfy,
    shouldThrow,
  )

spec :: Spec
spec = around withMaster $ do
  describe "cross-origin WebSocket upgrades" $ do
    it "accepts an allowed Origin with an initial snapshot" $ \master ->
      withServer originConfig master $ \port ->
        clientWithOrigin port [("Origin", "https://ops.example.com")] $ \conn -> do
          expected <- MetricsSnapshot <$> currentSnapshot master
          receiveServer conn `shouldReturn` expected

    it "refuses forbidden or multiple Origins with HTTP 403 before acquiring a slot" $ \master -> do
      wsState <- newWebSocketState 1
      let app = combinedApp originConfig master wsState []
      Warp.testWithApplication (pure app) $ \port -> do
        mapM_
          ( \headers -> do
              clientWithOrigin port headers receiveServer
                `shouldThrow` isForbiddenHandshake
              atomically (readTVar wsState.connectionCount) `shouldReturn` 0
          )
          [[("Origin", "https://evil.example.com")], [("Origin", "null")], [("Origin", "")], [("Origin", "https://ops.example.com"), ("origin", "https://ops.example.com")]]
        clientWithOrigin port [("Origin", "https://ops.example.com")] $ \conn -> do
          expected <- MetricsSnapshot <$> currentSnapshot master
          receiveServer conn `shouldReturn` expected

    it "allows clients without Origin when the policy is enabled" $ \master ->
      withServer originConfig master $ \port ->
        clientWithOrigin port [] $ \conn -> do
          expected <- MetricsSnapshot <$> currentSnapshot master
          receiveServer conn `shouldReturn` expected

    it "allows any Origin when the policy is disabled" $ \master ->
      withServer defaultConfig master $ \port ->
        clientWithOrigin port [("Origin", "https://evil.example.com")] $ \conn -> do
          expected <- MetricsSnapshot <$> currentSnapshot master
          receiveServer conn `shouldReturn` expected

  describe "controlled outbound delivery" $ do
    it "keeps sampling during a blocked write and sends an adjacent recovery pair" $ \master -> do
      handle <- registerIdleProcessor master (ProcessorId "alpha")
      withControlledServer fastConfig {wsMaxQueuedFrames = 2} master $ \port control ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          atomically $ writeTVar control.gate True
          incrementReceived handle
          _ <- tick control
          awaitBlocked control
          replicateM_ 3 $ incrementReceived handle >> tick control
          recovery <- tick control
          Out.queuedFrames recovery `shouldBe` 2
          map (eitherDecode @ServerMessage . LBS.fromStrict . Out.payload) (Out.entries recovery)
            `shouldSatisfy` (\case [Right (ServerError "queue_overflow" _), Right (MetricsSnapshot _)] -> True; _ -> False)
          atomically $ writeTVar control.gate False
          _ <- receiveServer conn -- the single already-popped update
          receiveServer conn `shouldReturn` ServerError "queue_overflow" "Updates dropped; replacing metrics snapshot"
          expected <- MetricsSnapshot <$> currentSnapshot master
          receiveServer conn `shouldReturn` expected
          WS.sendTextData conn $ encode Ping
          receiveServer conn `shouldReturn` Pong

    it "closes a malformed-frame flood with bounded required retention and slot recovery" $ \master ->
      withControlledServer fastConfig {wsMaxQueuedFrames = 2, wsSendTimeoutUs = 50_000} master $ \port control -> do
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          atomically $ writeTVar control.gate True
          WS.sendTextData conn $ encode Ping
          awaitBlocked control
          replicateM_ 8 $ WS.sendTextData conn ("{" :: ByteString)
          awaitReleased control.state
        atomically (readTVar control.state.connectionCount) `shouldReturn` 0

    it "refuses an initial snapshot larger than the byte budget and restores its slot" $ \master ->
      withControlledServer fastConfig {wsMaxQueuedBytes = 1} master $ \port control -> do
        WS.runClient
          "127.0.0.1"
          port
          "/ws"
          ( \conn ->
              (WS.receiveData conn :: IO ByteString) `shouldThrow` isCapacityClose
          )
        awaitReleased control.state

    it "flushes shutdown within one deadline even while a write is blocked" $ \master ->
      withControlledServer fastConfig {wsSendTimeoutUs = 50_000} master $ \port control ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          atomically $ writeTVar control.gate True
          WS.sendTextData conn $ encode Ping
          awaitBlocked control
          shutdownWebSockets control.state
          awaitReleased control.state

    it "orders shutdown goodbye after admitted errors" $ \master ->
      withControlledServer fastConfig {wsMaxQueuedFrames = 3} master $ \port control ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          atomically $ writeTVar control.gate True
          WS.sendTextData conn $ encode Ping
          awaitBlocked control
          atomically $ readTQueue control.received
          replicateM_ 2 $ do
            WS.sendTextData conn ("{\"type\":\"bogus\"}" :: ByteString)
            atomically $ readTQueue control.received
          shutdownWebSockets control.state
          timeout 1_000_000 (atomically $ readTQueue control.produced) >>= \case
            Just q -> Out.queuedFrames q `shouldBe` 3
            Nothing -> expectationFailure "shutdown did not queue goodbye"
          atomically $ writeTVar control.gate False
          receiveServer conn `shouldReturn` Pong
          replicateM_ 2 $ receiveServer conn `shouldReturn` ServerError "invalid_message" "Error in $: Unknown message type: bogus"
          receiveServer conn `shouldReturn` Goodbye
          (WS.receiveData conn :: IO ByteString) `shouldThrow` isNormalClose

    it "removes unsent old updates at an unsubscribe snapshot boundary" $ \master -> do
      handle <- registerIdleProcessor master (ProcessorId "alpha")
      withControlledServer fastConfig master $ \port control ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          atomically $ writeTVar control.gate True
          incrementReceived handle
          _ <- tick control
          awaitBlocked control
          incrementReceived handle
          _ <- tick control
          WS.sendTextData conn $ encode $ Unsubscribe [ProcessorId "alpha"]
          timeout 1_000_000 (atomically $ readTQueue control.received) `shouldReturn` Just ()
          WS.sendTextData conn $ encode Ping
          atomically $ writeTVar control.gate False
          _ <- receiveServer conn
          receiveServer conn `shouldReturn` MetricsSnapshot Map.empty
          receiveServer conn `shouldReturn` Pong
          _ <- tick control
          timeout 30_000 (receiveServer conn) `shouldReturn` Nothing

    it "stops ordinary deltas when terminal admission drops an update" $ \master -> do
      alpha <- registerIdleProcessor master (ProcessorId "alpha")
      beta <- registerIdleProcessor master (ProcessorId "beta")
      withControlledServer fastConfig {wsMaxQueuedFrames = 3} master $ \port control ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          atomically $ writeTVar control.gate True
          incrementReceived alpha
          _ <- tick control
          awaitBlocked control
          incrementReceived alpha
          _ <- tick control
          incrementReceived beta
          _ <- tick control
          incrementReceived alpha
          _ <- tick control
          markProcessorFailedIO master (ProcessorId "alpha") "boom" Nothing
          runEff $ unregisterProcessor master (ProcessorId "alpha")
          incrementReceived beta
          q <- tick control
          map Out.retention (Out.entries q) `shouldBe` [Out.Update, Out.Update, Out.Required]
          _ <- tick control
          atomically $ writeTVar control.gate False
          _ <- receiveServer conn
          receiveServer conn `shouldReturn` ProcessorTerminal (ProcessorId "alpha") (TerminalFailed "boom" Nothing)
          receiveServer conn `shouldReturn` ServerError "queue_overflow" "Updates dropped; replacing metrics snapshot"
          expected <- MetricsSnapshot <$> currentSnapshot master
          receiveServer conn `shouldReturn` expected

    it "preserves once-only terminal delivery before overflow recovery" $ \master -> do
      handle <- registerIdleProcessor master (ProcessorId "alpha")
      withControlledServer fastConfig {wsMaxQueuedFrames = 3} master $ \port control ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          atomically $ writeTVar control.gate True
          incrementReceived handle
          _ <- tick control
          awaitBlocked control
          replicateM_ 4 $ incrementReceived handle >> tick control
          markProcessorFailedIO master (ProcessorId "alpha") "boom" Nothing
          runEff $ unregisterProcessor master (ProcessorId "alpha")
          q <- tick control
          Out.queuedFrames q `shouldBe` 3
          atomically $ writeTVar control.gate False
          _ <- receiveServer conn
          receiveServer conn `shouldReturn` ProcessorTerminal (ProcessorId "alpha") (TerminalFailed "boom" Nothing)
          receiveServer conn `shouldReturn` ServerError "queue_overflow" "Updates dropped; replacing metrics snapshot"
          receiveServer conn `shouldReturn` MetricsSnapshot Map.empty
          _ <- tick control
          timeout 30_000 (receiveServer conn) `shouldReturn` Nothing

    it "bounds stopMetricsServer while a real peer leaves a large snapshot unread" $ \master -> do
      mapM_ (\n -> registerIdleProcessor master (ProcessorId $ "large-" <> fromString (show n))) [1 .. 30_000 :: Int]
      wsState <- newWebSocketState 1
      freePort <- Warp.testWithApplication (pure $ combinedApp defaultConfig master wsState []) pure
      let config = defaultConfig {port = freePort, wsMaxQueuedBytes = 32_000_000, wsSendTimeoutUs = 100_000}
      withMetricsServer config master $ \server -> do
        threadDelay 30_000 -- listener startup; no delay is used to trigger queue overflow
        WS.runClient "127.0.0.1" freePort "/ws" $ \_ -> do
          threadDelay 100_000
          timeout 500_000 (stopMetricsServer server) `shouldReturn` Just ()

    it "produces metrics during a continuous ping stream" $ \master -> do
      handle <- registerIdleProcessor master (ProcessorId "alpha")
      withServer fastConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          incrementReceived handle
          let findUpdate = do
                WS.sendTextData conn $ encode Ping
                receiveServer conn >>= \case
                  ProcessorUpdate _ _ -> pure ()
                  Pong -> findUpdate
                  other -> expectationFailure $ "unexpected frame: " <> show other
          timeout 500_000 findUpdate `shouldReturn` Just ()

  describe "WebSocket wire protocol" $ do
    it "reports invalid client messages and remains usable" $ \master ->
      withServer defaultConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          WS.sendTextData conn ("{\"type\":\"bogus\"}" :: ByteString)
          reply <- timeout 1_000_000 (WS.receiveData conn :: IO ByteString)
          fmap (eitherDecode @Value) reply
            `shouldBe` Just
              ( Right $
                  object
                    [ "type" .= ("error" :: String),
                      "code" .= ("invalid_message" :: String),
                      "message" .= ("Error in $: Unknown message type: bogus" :: String)
                    ]
              )
          WS.sendTextData conn $ encode Ping
          receiveServer conn `shouldReturn` Pong

    it "sends an initial snapshot" $ \master -> do
      _ <- registerIdleProcessor master (ProcessorId "alpha")
      withServer defaultConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          expected <- MetricsSnapshot <$> currentSnapshot master
          receiveServer conn `shouldReturn` expected

    it "answers subscribe_all and selective subscribe with snapshots" $ \master -> do
      _ <- registerIdleProcessor master (ProcessorId "alpha")
      _ <- registerIdleProcessor master (ProcessorId "beta")
      withServer defaultConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn

          WS.sendTextData conn $ encode SubscribeAll
          allSnapshot <- receiveServer conn
          expected <- MetricsSnapshot <$> currentSnapshot master
          allSnapshot `shouldBe` expected

          WS.sendTextData conn $ encode $ Subscribe [ProcessorId "alpha"]
          selective <- receiveServer conn
          case selective of
            MetricsSnapshot metrics -> Map.keys metrics `shouldBe` [ProcessorId "alpha"]
            other -> expectationFailure $ "expected selective snapshot, got " <> show other

    it "establishes an unsubscribe snapshot before subsequent replies" $ \master -> do
      _ <- registerIdleProcessor master (ProcessorId "alpha")
      withServer defaultConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          WS.sendTextData conn $ encode $ Unsubscribe [ProcessorId "alpha"]
          WS.sendTextData conn $ encode Ping
          receiveServer conn `shouldReturn` MetricsSnapshot Map.empty
          receiveServer conn `shouldReturn` Pong

    it "answers ping with pong" $ \master ->
      withServer defaultConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          WS.sendTextData conn $ encode Ping
          receiveServer conn `shouldReturn` Pong

    it "pushes an update after metrics change" $ \master -> do
      handle <- registerIdleProcessor master (ProcessorId "alpha")
      withServer fastConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          incrementReceived handle
          receiveServer conn >>= \case
            ProcessorUpdate (ProcessorId "alpha") ProcessorMetrics {stats = StreamStats {received}} -> received `shouldBe` 1
            other -> expectationFailure $ "expected processor update, got " <> show other

    it "does not push an update when metrics have not changed" $ \master -> do
      _ <- registerIdleProcessor master (ProcessorId "alpha")
      withServer fastConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          timeout 100_000 (receiveServer conn) `shouldReturn` Nothing

    it "rejects a connection beyond the configured limit" $ \master -> do
      let config = fastConfig {wsMaxConnections = 1}
      withServer config master $ \port -> do
        ready <- newEmptyMVar
        release <- newEmptyMVar
        first <- async $ holdConnection port ready release
        takeMVar ready
        (WS.runClient "127.0.0.1" port "/ws" $ \conn -> receiveServer conn)
          `shouldThrow` (anyException :: SomeException -> Bool)
        putMVar release ()
        wait first

    it "rejects WebSocket upgrades when disabled" $ \master ->
      withServer defaultConfig {enableWebSocket = False} master $ \port ->
        (WS.runClient "127.0.0.1" port "/ws" $ \conn -> receiveServer conn)
          `shouldThrow` (anyException :: SomeException -> Bool)

    it "closes clients that exceed the retained processor subscription limit" $ \master ->
      withServer fastConfig {wsMaxSubscriptions = 2} master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          WS.sendTextData conn $ encode $ Subscribe [ProcessorId "one", ProcessorId "two", ProcessorId "three"]
          payload <- timeout 1_000_000 (WS.receiveData conn :: IO ByteString)
          fmap (eitherDecode @Value) payload
            `shouldBe` Just
              ( Right $
                  object
                    [ "type" .= ("error" :: String),
                      "code" .= ("subscription_limit_exceeded" :: String),
                      "message" .= ("WebSocket processor subscription limit exceeded (maximum 2)" :: String)
                    ]
              )
          (WS.receiveData conn :: IO ByteString) `shouldThrow` isPolicyClose

    it "also bounds subscribe-all exclusion state" $ \master ->
      withServer fastConfig {wsMaxSubscriptions = 1} master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          WS.sendTextData conn $ encode $ Unsubscribe [ProcessorId "one", ProcessorId "two"]
          _ <- WS.receiveData conn :: IO ByteString
          (WS.receiveData conn :: IO ByteString) `shouldThrow` isPolicyClose

    it "excludes processors unsubscribed from subscribe-all" $ \master -> do
      alpha <- registerIdleProcessor master (ProcessorId "alpha")
      beta <- registerIdleProcessor master (ProcessorId "beta")
      withServer fastConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          WS.sendTextData conn $ encode $ Unsubscribe [ProcessorId "alpha"]
          _ <- receiveServer conn -- unsubscribe establishes the new generation snapshot
          incrementReceived alpha
          incrementReceived beta
          receiveServer conn >>= \case
            ProcessorUpdate pid _ -> pid `shouldBe` ProcessorId "beta"
            other -> expectationFailure $ "expected beta update, got " <> show other

    it "restores a slot after a peer disconnects" $ \master -> do
      wsState <- newWebSocketState 1
      let app = combinedApp fastConfig master wsState []
      Warp.testWithApplication (pure app) $ \port -> do
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          pure ()
        released <- timeout 1_000_000 $ atomically $ do
          count <- readTVar wsState.connectionCount
          check $ count == 0
        released `shouldBe` Just ()

    it "restores a slot when initial snapshot generation fails" $ \master -> do
      clockCalls <- newIORef (0 :: Int)
      let failingClock = do
            call <- atomicModifyIORef' clockCalls $ \count -> (count + 1, count)
            if call == 0 then pure 0 else throwIO $ userError "snapshot failed"
      handle <- newMetricsHandleWithClock failingClock fixedTime
      _ <- beginProcessing handle 1
      runEff $ registerProcessor master (ProcessorId "broken") handle
      wsState <- newWebSocketState 1
      let app = combinedApp fastConfig master wsState []
          quietSettings = Warp.setOnException (\_ _ -> pure ()) Warp.defaultSettings
      Warp.withApplicationSettings quietSettings (pure app) $ \port -> do
        _ <-
          try (WS.runClient "127.0.0.1" port "/ws" receiveServer) ::
            IO (Either SomeException ServerMessage)
        released <- timeout 1_000_000 $ atomically $ do
          count <- readTVar wsState.connectionCount
          check $ count == 0
        released `shouldBe` Just ()

    it "sends goodbye when WebSocket shutdown is requested" $ \master -> do
      wsState <- newWebSocketState 1
      let app = combinedApp fastConfig master wsState []
      Warp.testWithApplication (pure app) $ \port -> do
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          shutdownWebSockets wsState
          shutdownWebSockets wsState
          receiveServer conn `shouldReturn` Goodbye
        released <- timeout 1_000_000 $ atomically $ do
          count <- readTVar wsState.connectionCount
          check $ count == 0
        released `shouldBe` Just ()

    it "reports a retained terminal failure once when a processor disappears" $ \master -> do
      _ <- registerIdleProcessor master (ProcessorId "alpha")
      withServer fastConfig master $ \port ->
        WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
          _ <- receiveServer conn
          markProcessorFailedIO master (ProcessorId "alpha") "boom" (Just "message-1")
          runEff $ unregisterProcessor master (ProcessorId "alpha")
          receiveServer conn
            `shouldReturn` ProcessorTerminal
              (ProcessorId "alpha")
              (TerminalFailed "boom" (Just "message-1"))
          timeout 50_000 (receiveServer conn) `shouldReturn` Nothing

fastConfig :: MetricsServerConfig
fastConfig = defaultConfig {wsPushIntervalUs = 10_000}

withServer :: MetricsServerConfig -> Master -> (Int -> IO a) -> IO a
withServer config master action = do
  wsState <- newWebSocketState config.wsMaxConnections
  Warp.testWithApplication (pure $ combinedApp config master wsState []) action

currentSnapshot :: Master -> IO MetricsMap
currentSnapshot = getAllMetricsIO

receiveServer :: WS.Connection -> IO ServerMessage
receiveServer conn = do
  payload <- WS.receiveData conn :: IO ByteString
  case eitherDecode payload of
    Left err -> expectationFailure err >> fail err
    Right message -> pure message

holdConnection :: Int -> MVar () -> MVar () -> IO ()
holdConnection port ready release =
  WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
    _ <- receiveServer conn
    putMVar ready ()
    takeMVar release

shouldReturn :: (Eq a, Show a) => IO a -> a -> IO ()
shouldReturn action expected = action >>= (`shouldBe` expected)

originConfig :: MetricsServerConfig
originConfig = defaultConfig {corsAllowedOrigins = ["https://ops.example.com"], wsMaxConnections = 1}

clientWithOrigin :: Int -> WS.Headers -> WS.ClientApp a -> IO a
clientWithOrigin port = WS.runClientWith "127.0.0.1" port "/ws" WS.defaultConnectionOptions

isForbiddenHandshake :: WS.HandshakeException -> Bool
isForbiddenHandshake (WS.MalformedResponse response _) =
  WS.responseCode response == 403
    && lookup "Content-Type" (WS.responseHeaders response) == Just "application/json"
isForbiddenHandshake _ = False

isPolicyClose :: WS.ConnectionException -> Bool
isPolicyClose (WS.CloseRequest 1008 _) = True
isPolicyClose _ = False

data Controlled = Controlled
  { gate :: TVar Bool,
    started :: TQueue (),
    ticks :: TQueue (),
    produced :: TQueue Out.OutboundQueue,
    received :: TQueue (),
    state :: WebSocketState
  }

withControlledServer :: MetricsServerConfig -> Master -> (Int -> Controlled -> IO a) -> IO a
withControlledServer config master action = do
  control <-
    Controlled
      <$> newTVarIO False
      <*> newTQueueIO
      <*> newTQueueIO
      <*> newTQueueIO
      <*> newTQueueIO
      <*> newWebSocketState config.wsMaxConnections
  let hooks =
        defaultWebSocketHooks
          { beforeWrite = \_ -> do
              atomically $ readTVar control.gate >>= \blocked -> when blocked (writeTQueue control.started ())
              atomically $ readTVar control.gate >>= check . not,
            afterReceive = \q -> do
              Out.queuedFrames q `shouldSatisfy` (<= config.wsMaxQueuedFrames)
              Out.queuedBytes q `shouldSatisfy` (<= config.wsMaxQueuedBytes)
              atomically $ writeTQueue control.received (),
            afterProduce = \q -> do
              Out.queuedFrames q `shouldSatisfy` (<= config.wsMaxQueuedFrames)
              Out.queuedBytes q `shouldSatisfy` (<= config.wsMaxQueuedBytes)
              atomically $ writeTQueue control.produced q,
            waitForPush = \_ state ->
              atomically $
                (readTVar state.shutdownRequested >>= \requested -> check requested >> pure True)
                  `orElse` (readTQueue control.ticks >> pure False)
          }
      app =
        WaiWS.websocketsOr
          WS.defaultConnectionOptions
          (websocketAppWithHooks hooks config master control.state)
          (combinedApp config {enableWebSocket = False} master control.state [])
  Warp.testWithApplication (pure app) $ \port -> action port control

tick :: Controlled -> IO Out.OutboundQueue
tick control = do
  atomically $ writeTQueue control.ticks ()
  timeout 1_000_000 (atomically $ readTQueue control.produced) >>= \case
    Just queue -> do
      Out.queuedFrames queue `shouldSatisfy` (<= 64)
      Out.queuedBytes queue `shouldSatisfy` (<= 1_048_576)
      pure queue
    Nothing -> expectationFailure "producer did not complete while writer was blocked" >> fail "producer stalled"

awaitBlocked :: Controlled -> IO ()
awaitBlocked control = timeout 1_000_000 (atomically $ readTQueue control.started) `shouldReturn` Just ()

awaitReleased :: WebSocketState -> IO ()
awaitReleased state = timeout 500_000 (atomically $ readTVar state.connectionCount >>= check . (== 0)) `shouldReturn` Just ()

isCapacityClose :: WS.ConnectionException -> Bool
isCapacityClose (WS.CloseRequest 1013 _) = True
isCapacityClose _ = False

isNormalClose :: WS.ConnectionException -> Bool
isNormalClose (WS.CloseRequest 1000 _) = True
isNormalClose _ = False
