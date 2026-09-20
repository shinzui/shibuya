module Shibuya.Metrics.JSONSpec (spec) where

import Data.Aeson (encode)
import Shibuya.Metrics.TestSupport (assertGolden, fixtureMetrics)
import Test.Hspec (Spec, describe, it)

spec :: Spec
spec =
  describe "JSON wire contract" $
    it "matches the golden encoding for all four processor states" $
      assertGolden "processor-metrics.json.golden" (encode fixtureMetrics <> "\n")
