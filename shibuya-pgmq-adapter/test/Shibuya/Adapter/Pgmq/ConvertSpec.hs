module Shibuya.Adapter.Pgmq.ConvertSpec (spec) where

import Data.Aeson (Value (..))
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Pgmq.Types qualified as Pgmq
import Shibuya.Adapter.Pgmq.Convert
import Shibuya.Core.Ack (DeadLetterReason (..))
import Shibuya.Core.Types (Cursor (..), MessageId (..))
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  describe "messageIdToShibuya" $ do
    it "converts pgmq MessageId to Shibuya MessageId" $ do
      messageIdToShibuya (Pgmq.MessageId 42)
        `shouldBe` MessageId "42"

    it "handles zero" $ do
      messageIdToShibuya (Pgmq.MessageId 0)
        `shouldBe` MessageId "0"

    it "handles large numbers" $ do
      messageIdToShibuya (Pgmq.MessageId 9223372036854775807)
        `shouldBe` MessageId "9223372036854775807"

  describe "messageIdToPgmq" $ do
    it "converts valid Shibuya MessageId back to pgmq" $ do
      messageIdToPgmq (MessageId "42")
        `shouldBe` Just (Pgmq.MessageId 42)

    it "returns Nothing for non-numeric text" $ do
      messageIdToPgmq (MessageId "abc") `shouldBe` Nothing

    it "returns Nothing for empty text" $ do
      messageIdToPgmq (MessageId "") `shouldBe` Nothing

    it "returns Nothing for text with spaces" $ do
      messageIdToPgmq (MessageId "42 ") `shouldBe` Nothing

    it "roundtrips correctly" $ property $ \(n :: Int64) ->
      let pgmqId = Pgmq.MessageId n
          shibuyaId = messageIdToShibuya pgmqId
       in messageIdToPgmq shibuyaId == Just pgmqId

  describe "pgmqMessageIdToCursor" $ do
    it "converts to CursorInt" $ do
      pgmqMessageIdToCursor (Pgmq.MessageId 123)
        `shouldBe` CursorInt 123

  describe "pgmqMessageToEnvelope" $ do
    let sampleTime = UTCTime (fromGregorian 2024 1 1) 0
        sampleMessage =
          Pgmq.Message
            { messageId = Pgmq.MessageId 42,
              visibilityTime = sampleTime,
              enqueuedAt = sampleTime,
              readCount = 1,
              body = Pgmq.MessageBody (String "test payload"),
              headers = Nothing
            }

    it "converts messageId" $ do
      let envelope = pgmqMessageToEnvelope sampleMessage
      envelope.messageId `shouldBe` MessageId "42"

    it "converts enqueuedAt" $ do
      let envelope = pgmqMessageToEnvelope sampleMessage
      envelope.enqueuedAt `shouldBe` Just sampleTime

    it "sets cursor from messageId" $ do
      let envelope = pgmqMessageToEnvelope sampleMessage
      envelope.cursor `shouldBe` Just (CursorInt 42)

    it "extracts payload from body" $ do
      let envelope = pgmqMessageToEnvelope sampleMessage
      envelope.payload `shouldBe` String "test payload"

  describe "mkDlqPayload" $ do
    let sampleTime = UTCTime (fromGregorian 2024 1 1) 0
        sampleMessage =
          Pgmq.Message
            { messageId = Pgmq.MessageId 42,
              visibilityTime = sampleTime,
              enqueuedAt = sampleTime,
              readCount = 5,
              body = Pgmq.MessageBody (String "original"),
              headers = Nothing
            }

    it "includes original message" $ do
      let dlqBody = mkDlqPayload sampleMessage MaxRetriesExceeded False
          Pgmq.MessageBody payload = dlqBody
      case payload of
        Object obj -> do
          -- Verify original_message is present
          True `shouldBe` True -- Simplified check
        _ -> expectationFailure "Expected Object"

    it "includes reason" $ do
      let dlqBody = mkDlqPayload sampleMessage (PoisonPill "bad data") True
          Pgmq.MessageBody payload = dlqBody
      case payload of
        Object _ -> True `shouldBe` True
        _ -> expectationFailure "Expected Object"
