module Shibuya.Adapter.Pgmq.ConfigSpec (spec) where

import Pgmq.Types (parseQueueName, parseRoutingKey)
import Shibuya.Adapter.Pgmq.Config
import Test.Hspec

spec :: Spec
spec = do
  defaultConfigSpec
  defaultPollingConfigSpec
  defaultPrefetchConfigSpec
  deadLetterTargetSpec
  smartConstructorSpec

-- | Tests for defaultConfig
defaultConfigSpec :: Spec
defaultConfigSpec = describe "defaultConfig" $ do
  let queueName = case parseQueueName "test_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
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

-- | Tests for DeadLetterTarget
deadLetterTargetSpec :: Spec
deadLetterTargetSpec = describe "DeadLetterTarget" $ do
  let queueName = case parseQueueName "dlq_test" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      routingKey = case parseRoutingKey "dlq.errors" of
        Right r -> r
        Left e -> error $ "Unexpected: " <> show e

  it "DirectQueue holds a queue name" $ do
    let target = DirectQueue queueName
    case target of
      DirectQueue q -> q `shouldBe` queueName
      TopicRoute _ -> expectationFailure "Expected DirectQueue"

  it "TopicRoute holds a routing key" $ do
    let target = TopicRoute routingKey
    case target of
      TopicRoute r -> r `shouldBe` routingKey
      DirectQueue _ -> expectationFailure "Expected TopicRoute"

  it "DirectQueue and TopicRoute are not equal" $ do
    DirectQueue queueName `shouldNotBe` TopicRoute routingKey

-- | Tests for smart constructors
smartConstructorSpec :: Spec
smartConstructorSpec = describe "Smart constructors" $ do
  let queueName = case parseQueueName "dlq_test" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      routingKey = case parseRoutingKey "dlq.errors" of
        Right r -> r
        Left e -> error $ "Unexpected: " <> show e

  describe "directDeadLetter" $ do
    it "creates a DeadLetterConfig with DirectQueue target" $ do
      let config = directDeadLetter queueName True
      config.dlqTarget `shouldBe` DirectQueue queueName

    it "sets includeMetadata correctly" $ do
      let config = directDeadLetter queueName False
      config.includeMetadata `shouldBe` False

  describe "topicDeadLetter" $ do
    it "creates a DeadLetterConfig with TopicRoute target" $ do
      let config = topicDeadLetter routingKey True
      config.dlqTarget `shouldBe` TopicRoute routingKey

    it "sets includeMetadata correctly" $ do
      let config = topicDeadLetter routingKey False
      config.includeMetadata `shouldBe` False
