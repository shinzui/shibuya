module Main (main) where

import Shibuya.Metrics.HealthSpec qualified
import Shibuya.Metrics.JSONSpec qualified
import Shibuya.Metrics.PrometheusSpec qualified
import Shibuya.Metrics.ServerSpec qualified
import Shibuya.Metrics.TypesSpec qualified
import Shibuya.Metrics.WebSocketSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  Shibuya.Metrics.ServerSpec.spec
  Shibuya.Metrics.JSONSpec.spec
  Shibuya.Metrics.PrometheusSpec.spec
  Shibuya.Metrics.TypesSpec.spec
  Shibuya.Metrics.WebSocketSpec.spec
  Shibuya.Metrics.HealthSpec.spec
