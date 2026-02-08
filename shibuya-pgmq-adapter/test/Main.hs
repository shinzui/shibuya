module Main (main) where

import Shibuya.Adapter.Pgmq.ChaosSpec qualified as ChaosSpec
import Shibuya.Adapter.Pgmq.ConfigSpec qualified as ConfigSpec
import Shibuya.Adapter.Pgmq.ConvertSpec qualified as ConvertSpec
import Shibuya.Adapter.Pgmq.IntegrationSpec qualified as IntegrationSpec
import Shibuya.Adapter.Pgmq.InternalSpec qualified as InternalSpec
import Shibuya.Adapter.Pgmq.PropertySpec qualified as PropertySpec
import Test.Hspec

main :: IO ()
main = hspec $ do
  describe "Unit Tests" $ do
    describe "Shibuya.Adapter.Pgmq.Convert" ConvertSpec.spec
    describe "Shibuya.Adapter.Pgmq.Config" ConfigSpec.spec
    describe "Shibuya.Adapter.Pgmq.Internal" InternalSpec.spec
  describe "Property Tests" $ do
    describe "Shibuya.Adapter.Pgmq Properties" PropertySpec.spec
  describe "Integration Tests" IntegrationSpec.spec
  describe "Chaos Tests" ChaosSpec.spec
