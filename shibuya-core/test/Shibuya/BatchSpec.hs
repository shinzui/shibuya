module Shibuya.BatchSpec (spec) where

import Data.Map.Strict qualified as Map
import Shibuya.Batch
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.Types (MessageId (..))
import Test.Hspec

-- | A concrete 'BatchConfig' so field access and 'validateBatchConfig' resolve
-- without ambiguous @es@/@msg@ type variables.
cfg :: BatchConfig '[] Int
cfg = defaultBatchConfig

spec :: Spec
spec = describe "Shibuya.Batch" $ do
  describe "defaultBatchConfig" $ do
    it "has size 100 and 1s timeout" $ do
      cfg.batchSize `shouldBe` 100
      cfg.batchTimeout `shouldBe` 1
    it "routes every message to the default key" $
      cfg.batchKey undefined `shouldBe` defaultBatchKey

  describe "validateBatchConfig" $ do
    it "accepts the default config" $
      validateBatchConfig cfg `shouldBe` Right ()
    it "rejects size 0" $
      validateBatchConfig cfg {batchSize = 0}
        `shouldBe` Left (BatchSizeNotPositive 0)
    it "rejects non-positive timeout" $
      validateBatchConfig cfg {batchTimeout = 0}
        `shouldBe` Left (BatchTimeoutNotPositive 0)
    it "rejects non-positive tick interval" $
      validateBatchConfig cfg {tickInterval = Just 0}
        `shouldBe` Left (TickIntervalNotPositive 0)

  describe "BatchAck smart constructors" $ do
    it "ackAllOk falls back to AckOk with no overrides" $ do
      ackAllOk.fallback `shouldBe` AckOk
      Map.null ackAllOk.decisions `shouldBe` True
    it "ackAll sets the fallback for everything" $ do
      let a = ackAll (AckRetry (RetryDelay 5))
      Map.null a.decisions `shouldBe` True
      a.fallback `shouldBe` AckRetry (RetryDelay 5)
    it "ackExcept keeps AckOk fallback and records overrides" $ do
      let a = ackExcept [(MessageId "m1", AckDeadLetter MaxRetriesExceeded)]
      a.fallback `shouldBe` AckOk
      Map.lookup (MessageId "m1") a.decisions
        `shouldBe` Just (AckDeadLetter MaxRetriesExceeded)
    it "failMessages dead-letters the listed ids" $ do
      let a = failMessages [(MessageId "bad", PoisonPill "nope")]
      a.fallback `shouldBe` AckOk
      Map.lookup (MessageId "bad") a.decisions
        `shouldBe` Just (AckDeadLetter (PoisonPill "nope"))
    it "withFallback uses the given fallback" $ do
      let a = withFallback (AckDeadLetter MaxRetriesExceeded) [(MessageId "ok", AckOk)]
      a.fallback `shouldBe` AckDeadLetter MaxRetriesExceeded
      Map.lookup (MessageId "ok") a.decisions `shouldBe` Just AckOk
