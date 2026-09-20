module Shibuya.Metrics.HealthSpec (spec) where

import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Metrics.Health
  ( DependencyStatus (..),
    LivenessStatus (..),
    ProcessorHealth (..),
    ReadinessStatus (..),
    checkDetailedHealth,
    checkLiveness,
    checkReadiness,
    defaultHealthConfig,
  )
import Shibuya.Metrics.TestSupport (registerFailedProcessor, withMaster)
import Test.Hspec (Spec, around, describe, it, shouldBe)

spec :: Spec
spec = around withMaster $ do
  describe "health characterization" $ do
    it "reports a running, intentionally empty master live and ready" $ \master -> do
      checkLiveness defaultHealthConfig master `shouldReturn` LivenessStatus {alive = True}
      checkReadiness defaultHealthConfig master []
        `shouldReturn` ReadinessStatus
          { ready = True,
            processors = ProcessorHealth {total = 0, healthy = 0, failed = 0, stuck = 0},
            dependencies = []
          }

    it "reports a failed processor while it remains registered" $ \master -> do
      _ <- registerFailedProcessor master (ProcessorId "failed")
      readiness <- checkReadiness defaultHealthConfig master []
      readiness.ready `shouldBe` False
      readiness.processors `shouldBe` ProcessorHealth {total = 1, healthy = 0, failed = 1, stuck = 0}

      (detailed, metrics) <- checkDetailedHealth defaultHealthConfig master []
      detailed `shouldBe` readiness
      length metrics `shouldBe` 1

    it "reports an unhealthy dependency unready with its diagnostic fields" $ \master -> do
      let dependency =
            DependencyStatus
              { name = "database",
                healthy = False,
                latencyMs = Just 7,
                errorMsg = Just "unavailable"
              }
      readiness <- checkReadiness defaultHealthConfig master [pure dependency]
      readiness.ready `shouldBe` False
      readiness.dependencies `shouldBe` [dependency]

shouldReturn :: (Eq a, Show a) => IO a -> a -> IO ()
shouldReturn action expected = action >>= (`shouldBe` expected)
