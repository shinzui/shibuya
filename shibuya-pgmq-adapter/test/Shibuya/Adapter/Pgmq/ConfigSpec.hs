module Shibuya.Adapter.Pgmq.ConfigSpec (spec) where

import Pgmq.Types (parseQueueName)
import Shibuya.Adapter.Pgmq.Config
import Test.Hspec

spec :: Spec
spec = do
  defaultConfigSpec
  defaultPollingConfigSpec
  defaultPrefetchConfigSpec

-- | Tests for defaultConfig
defaultConfigSpec :: Spec
defaultConfigSpec = describe "defaultConfig" $ do
  let Right queueName = parseQueueName "test_queue"
      config = defaultConfig queueName

  it "sets queueName from parameter" $ do
    config.queueName `shouldBe` queueName

  it "sets visibilityTimeout to 30" $ do
    config.visibilityTimeout `shouldBe` 30

  it "sets batchSize to 1" $ do
    config.batchSize `shouldBe` 1

  it "uses StandardPolling with 1 second interval" $ do
    case config.polling of
      StandardPolling interval -> interval `shouldBe` 1
      _ -> expectationFailure "Expected StandardPolling"

  it "sets deadLetterConfig to Nothing" $ do
    config.deadLetterConfig `shouldBe` Nothing

  it "sets maxRetries to 3" $ do
    config.maxRetries `shouldBe` 3

  it "sets fifoConfig to Nothing" $ do
    config.fifoConfig `shouldBe` Nothing

  it "sets prefetchConfig to Nothing" $ do
    config.prefetchConfig `shouldBe` Nothing

-- | Tests for defaultPollingConfig
defaultPollingConfigSpec :: Spec
defaultPollingConfigSpec = describe "defaultPollingConfig" $ do
  it "is StandardPolling" $ do
    case defaultPollingConfig of
      StandardPolling _ -> pure ()
      _ -> expectationFailure "Expected StandardPolling"

  it "has 1 second interval" $ do
    case defaultPollingConfig of
      StandardPolling interval -> interval `shouldBe` 1
      _ -> expectationFailure "Expected StandardPolling"

-- | Tests for defaultPrefetchConfig
defaultPrefetchConfigSpec :: Spec
defaultPrefetchConfigSpec = describe "defaultPrefetchConfig" $ do
  it "has bufferSize of 4" $ do
    defaultPrefetchConfig.bufferSize `shouldBe` 4
