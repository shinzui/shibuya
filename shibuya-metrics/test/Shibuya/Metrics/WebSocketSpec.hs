module Shibuya.Metrics.WebSocketSpec (spec) where

import Control.Concurrent (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.Async (async, wait)
import Control.Exception (SomeException)
import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy (ByteString)
import Data.Map.Strict qualified as Map
import Network.Wai.Handler.Warp qualified as Warp
import Network.WebSockets qualified as WS
import Shibuya.App (Master, getAllMetricsIO)
import Shibuya.Core.Metrics
  ( MetricsMap,
    ProcessorId (..),
    ProcessorMetrics (..),
    StreamStats (..),
    incrementReceived,
  )
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Server (combinedApp)
import Shibuya.Metrics.TestSupport
  ( registerIdleProcessor,
    withMaster,
  )
import Shibuya.Metrics.Types (ClientMessage (..), ServerMessage (..))
import Shibuya.Metrics.WebSocket (newWebSocketState)
import System.Timeout (timeout)
import Test.Hspec
  ( Spec,
    anyException,
    around,
    describe,
    expectationFailure,
    it,
    shouldBe,
    shouldThrow,
  )

spec :: Spec
spec = around withMaster $ do
  describe "WebSocket wire protocol" $ do
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
