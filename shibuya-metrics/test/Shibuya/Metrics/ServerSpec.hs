module Shibuya.Metrics.ServerSpec (spec) where

import Control.Exception (throwIO)
import Data.Aeson (decode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Network.HTTP.Types (Status, hContentType, status200, status404, status503)
import Network.Wai (Application)
import Network.Wai.Test (SResponse (..))
import Shibuya.App (Master)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Health (DependencyCheck, DependencyStatus (..))
import Shibuya.Metrics.Server (combinedApp)
import Shibuya.Metrics.TestSupport
  ( getResponse,
    registerIdleProcessor,
    withMaster,
  )
import Shibuya.Metrics.WebSocket (newWebSocketState)
import Test.Hspec (Spec, around, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = around withMaster $ do
  describe "combinedApp HTTP routes" $ do
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
        `shouldBe` Just (object ["error" .= ("WebSocket endpoint - use ws:// protocol" :: String)])

    it "returns the published JSON error for an unknown processor" $ \master -> do
      app <- appFor defaultConfig master []
      response <- getResponse app "/metrics/missing"
      response.simpleStatus `shouldBe` status404
      decode response.simpleBody
        `shouldBe` Just
          ( object
              [ "error" .= ("Processor not found" :: String),
                "processor" .= ("missing" :: String)
              ]
          )

    it "returns the published JSON error for an unknown path" $ \master -> do
      app <- appFor defaultConfig master []
      response <- getResponse app "/unknown"
      response.simpleStatus `shouldBe` status404
      decode response.simpleBody
        `shouldBe` Just (object ["error" .= ("Not found" :: String)])

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
        `shouldBe` Just (object ["error" .= ("Not found" :: String)])

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
