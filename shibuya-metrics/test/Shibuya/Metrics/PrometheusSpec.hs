module Shibuya.Metrics.PrometheusSpec (spec) where

import Network.HTTP.Types (status200)
import Network.Wai.Test (SResponse (..))
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Server (combinedApp)
import Shibuya.Metrics.TestSupport
  ( assertGolden,
    getResponse,
    registerPrometheusFixtures,
    withMaster,
  )
import Shibuya.Metrics.WebSocket (newWebSocketState)
import Test.Hspec (Spec, around, describe, it, shouldBe)

spec :: Spec
spec = around withMaster $
  describe "Prometheus wire contract" $
    it "matches the golden series names, labels, state values, and counters" $ \master -> do
      registerPrometheusFixtures master
      wsState <- newWebSocketState defaultConfig.wsMaxConnections
      response <- getResponse (combinedApp defaultConfig master wsState []) "/metrics/prometheus"
      response.simpleStatus `shouldBe` status200
      assertGolden "prometheus.golden" response.simpleBody
