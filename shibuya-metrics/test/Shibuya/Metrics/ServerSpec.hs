module Shibuya.Metrics.ServerSpec (spec) where

import Control.Exception (SomeException, throwIO)
import Data.Aeson (decode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Char (toLower)
import Data.List (isInfixOf)
import Network.HTTP.Types (Status, hContentType, status200, status404, status503)
import Network.Wai (Application, requestHeaders)
import Network.Wai.Test (SResponse (..), defaultRequest, request, runSession, setPath)
import Shibuya.App (Master)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Error (errorResponse)
import Shibuya.Metrics.Health (DependencyCheck, DependencyStatus (..))
import Shibuya.Metrics.Server (combinedApp, startMetricsServer)
import Shibuya.Metrics.TestSupport
  ( getResponse,
    registerIdleProcessor,
    withMaster,
  )
import Shibuya.Metrics.WebSocket (newWebSocketState)
import Test.Hspec (Spec, anyException, around, describe, it, shouldBe, shouldSatisfy, shouldThrow)

spec :: Spec
spec = around withMaster $ do
  describe "built-in server configuration" $ do
    it "defaults to a loopback-only listener" $ \_ ->
      defaultConfig.host `shouldBe` "127.0.0.1"

    it "validates frame, byte, and send budgets before opening a socket" $ \master ->
      mapM_
        (\config -> startMetricsServer config master `shouldThrow` anyException)
        [ defaultConfig {wsMaxQueuedFrames = 0},
          defaultConfig {wsMaxQueuedFrames = 1},
          defaultConfig {wsMaxQueuedBytes = 0},
          defaultConfig {wsSendTimeoutUs = 0}
        ]

    it "rejects nonpositive WebSocket resource limits" $ \master ->
      startMetricsServer defaultConfig {wsMaxSubscriptions = 0} master
        `shouldThrow` (anyException :: SomeException -> Bool)

  describe "structured error response" $ do
    it "protects reserved keys while retaining context and content type" $ \_ -> do
      let app _ respond =
            respond $
              errorResponse
                status404
                "Not found"
                "not_found"
                ["error" .= ("override" :: String), "code" .= ("override" :: String), "processor" .= ("missing" :: String)]
      response <- getResponse app "/"
      response.simpleStatus `shouldBe` status404
      lookup hContentType response.simpleHeaders `shouldBe` Just "application/json"
      decode response.simpleBody
        `shouldBe` Just
          ( object
              ["error" .= ("Not found" :: String), "code" .= ("not_found" :: String), "processor" .= ("missing" :: String)]
          )

  describe "combinedApp HTTP routes" $ do
    it "preserves headerless defaults on every read route with an Origin" $ \master -> do
      _ <- registerIdleProcessor master (ProcessorId "known")
      app <- appFor defaultConfig master []
      mapM_
        ( \path -> do
            plain <- getResponse app path
            origin <- runSession (request $ setPath defaultRequest {requestHeaders = [("Origin", "https://ops.example.com")]} path) app
            origin.simpleHeaders `shouldBe` plain.simpleHeaders
            origin.simpleHeaders `shouldSatisfy` (not . any (\(name, _) -> "access-control-" `isInfixOf` map toLower (show name)))
            lookup "Vary" origin.simpleHeaders `shouldBe` Nothing
        )
        ["/metrics", "/metrics/known", "/metrics/missing", "/metrics/prometheus", "/health", "/health/live", "/health/ready", "/ws", "/unknown"]

    it "serves every enabled JSON, health, Prometheus, and WebSocket path" $ \master -> do
      _ <- registerIdleProcessor master (ProcessorId "known")
      app <- appFor defaultConfig master []

      assertResponse app "/metrics" status200 (Just "application/json")
      assertResponse app "/metrics/known" status200 (Just "application/json")
      assertResponse app "/health" status200 (Just "application/json")
      assertResponse app "/health/live" status200 (Just "application/json")
      assertResponse app "/health/ready" status200 (Just "application/json")
      assertResponse app "/metrics/prometheus" status200 (Just "text/plain; version=0.0.4; charset=utf-8")

      wsResponse <- getResponse app "/ws"
      wsResponse.simpleStatus `shouldBe` status404
      decode wsResponse.simpleBody
        `shouldBe` Just (object ["error" .= ("WebSocket endpoint - use ws:// protocol" :: String), "code" .= ("websocket_upgrade_required" :: String)])

    it "returns the published JSON error for an unknown processor" $ \master -> do
      app <- appFor defaultConfig master []
      response <- getResponse app "/metrics/missing"
      response.simpleStatus `shouldBe` status404
      decode response.simpleBody
        `shouldBe` Just
          ( object
              [ "error" .= ("Processor not found" :: String),
                "processor" .= ("missing" :: String),
                "code" .= ("processor_not_found" :: String)
              ]
          )

    it "returns the published JSON error for an unknown path" $ \master -> do
      app <- appFor defaultConfig master []
      response <- getResponse app "/unknown"
      response.simpleStatus `shouldBe` status404
      decode response.simpleBody
        `shouldBe` Just (object ["error" .= ("Not found" :: String), "code" .= ("not_found" :: String)])

    it "returns 404 for every JSON route when JSON endpoints are disabled" $ \master -> do
      app <- appFor defaultConfig {enableJSON = False} master []
      mapM_
        (\path -> assertResponse app path status404 (Just "application/json"))
        ["/metrics", "/metrics/known", "/health", "/health/live", "/health/ready"]

    it "returns 404 when Prometheus is disabled" $ \master -> do
      app <- appFor defaultConfig {enablePrometheus = False} master []
      assertResponse app "/metrics/prometheus" status404 (Just "application/json")

    it "uses the generic 404 for plain HTTP when WebSockets are disabled" $ \master -> do
      app <- appFor defaultConfig {enableWebSocket = False} master []
      response <- getResponse app "/ws"
      response.simpleStatus `shouldBe` status404
      decode response.simpleBody
        `shouldBe` Just (object ["error" .= ("Not found" :: String), "code" .= ("not_found" :: String)])

    it "returns 503 from readiness and detailed health for an unhealthy dependency" $ \master -> do
      app <- appFor defaultConfig master [failingDependency]
      assertResponse app "/health" status503 (Just "application/json")
      assertResponse app "/health/ready" status503 (Just "application/json")

    it "returns 503 when a dependency check throws synchronously" $ \master -> do
      app <- appFor defaultConfig master [throwIO $ userError "database exploded"]
      assertResponse app "/health" status503 (Just "application/json")
      assertResponse app "/health/ready" status503 (Just "application/json")

appFor :: MetricsServerConfig -> Master -> [DependencyCheck] -> IO Application
appFor config master dependencies = do
  wsState <- newWebSocketState config.wsMaxConnections
  pure $ combinedApp config master wsState dependencies

assertResponse :: Application -> ByteString -> Status -> Maybe ByteString -> IO ()
assertResponse app path expectedStatus expectedContentType = do
  response <- getResponse app path
  response.simpleStatus `shouldBe` expectedStatus
  lookup hContentType response.simpleHeaders `shouldBe` expectedContentType
  response.simpleBody `shouldSatisfy` (not . LBS.null)

failingDependency :: DependencyCheck
failingDependency =
  pure
    DependencyStatus
      { name = "database",
        healthy = False,
        latencyMs = Just 7,
        errorMsg = Just "unavailable"
      }
