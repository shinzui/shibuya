module Shibuya.Adapter.Pgmq.InternalSpec (spec) where

import Pgmq.Hasql.Statements.Types (ReadGrouped (..), ReadMessage (..), ReadWithPollMessage (..))
import Pgmq.Types (parseQueueName)
import Shibuya.Adapter.Pgmq.Config
  ( PgmqAdapterConfig (..),
    defaultPollingConfig,
  )
import Shibuya.Adapter.Pgmq.Internal
  ( mkReadGrouped,
    mkReadMessage,
    mkReadWithPoll,
    nominalToSeconds,
  )
import Test.Hspec

spec :: Spec
spec = do
  nominalToSecondsSpec
  mkReadMessageSpec
  mkReadWithPollSpec
  mkReadGroupedSpec

-- | Tests for nominalToSeconds
nominalToSecondsSpec :: Spec
nominalToSecondsSpec = describe "nominalToSeconds" $ do
  it "converts whole seconds" $ do
    nominalToSeconds 5 `shouldBe` 5

  it "rounds up fractional seconds" $ do
    nominalToSeconds 5.1 `shouldBe` 6

  it "rounds up small fractions" $ do
    nominalToSeconds 5.001 `shouldBe` 6

  it "handles zero" $ do
    nominalToSeconds 0 `shouldBe` 0

  it "handles negative (rounds toward positive infinity)" $ do
    nominalToSeconds (-5.1) `shouldBe` (-5)

-- | Tests for mkReadMessage
mkReadMessageSpec :: Spec
mkReadMessageSpec = describe "mkReadMessage" $ do
  let queueName = case parseQueueName "test_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      config =
        PgmqAdapterConfig
          { queueName = queueName,
            visibilityTimeout = 60,
            batchSize = 10,
            polling = defaultPollingConfig,
            deadLetterConfig = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing,
            prefetchConfig = Nothing
          }
      ReadMessage
        { queueName = queryQueueName,
          delay = queryDelay,
          batchSize = queryBatchSize,
          conditional = queryConditional
        } = mkReadMessage config

  it "sets queueName from config" $ do
    queryQueueName `shouldBe` queueName

  it "sets delay to visibilityTimeout" $ do
    queryDelay `shouldBe` 60

  it "sets batchSize from config" $ do
    queryBatchSize `shouldBe` Just 10

  it "sets conditional to Nothing" $ do
    queryConditional `shouldBe` Nothing

-- | Tests for mkReadWithPoll
mkReadWithPollSpec :: Spec
mkReadWithPollSpec = describe "mkReadWithPoll" $ do
  let queueName = case parseQueueName "test_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      config =
        PgmqAdapterConfig
          { queueName = queueName,
            visibilityTimeout = 60,
            batchSize = 10,
            polling = defaultPollingConfig,
            deadLetterConfig = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing,
            prefetchConfig = Nothing
          }
      ReadWithPollMessage
        { queueName = queryQueueName,
          delay = queryDelay,
          batchSize = queryBatchSize,
          maxPollSeconds = queryMaxPoll,
          pollIntervalMs = queryPollInterval,
          conditional = queryConditional
        } = mkReadWithPoll config 5 100

  it "sets queueName from config" $ do
    queryQueueName `shouldBe` queueName

  it "sets delay to visibilityTimeout" $ do
    queryDelay `shouldBe` 60

  it "sets batchSize from config" $ do
    queryBatchSize `shouldBe` Just 10

  it "sets maxPollSeconds from parameter" $ do
    queryMaxPoll `shouldBe` 5

  it "sets pollIntervalMs from parameter" $ do
    queryPollInterval `shouldBe` 100

  it "sets conditional to Nothing" $ do
    queryConditional `shouldBe` Nothing

-- | Tests for mkReadGrouped
mkReadGroupedSpec :: Spec
mkReadGroupedSpec = describe "mkReadGrouped" $ do
  let queueName = case parseQueueName "test_queue" of
        Right q -> q
        Left e -> error $ "Unexpected: " <> show e
      config =
        PgmqAdapterConfig
          { queueName = queueName,
            visibilityTimeout = 60,
            batchSize = 20,
            polling = defaultPollingConfig,
            deadLetterConfig = Nothing,
            maxRetries = 3,
            fifoConfig = Nothing,
            prefetchConfig = Nothing
          }
      ReadGrouped
        { queueName = queryQueueName,
          visibilityTimeout = queryVt,
          qty = queryQty
        } = mkReadGrouped config

  it "sets queueName from config" $ do
    queryQueueName `shouldBe` queueName

  it "sets visibilityTimeout from config" $ do
    queryVt `shouldBe` 60

  it "sets qty to batchSize" $ do
    queryQty `shouldBe` 20
