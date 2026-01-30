module Shibuya.Adapter.Pgmq.PropertySpec (spec) where

import Data.Aeson (Value (..))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Pgmq.Types qualified as Pgmq
import Shibuya.Adapter.Pgmq.Convert
  ( messageIdToPgmq,
    messageIdToShibuya,
    mkDlqPayload,
    pgmqMessageIdToCursor,
    pgmqMessageToEnvelope,
  )
import Shibuya.Core.Ack (DeadLetterReason (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..))
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Instances.Text ()

spec :: Spec
spec = do
  messageIdConversionProperties
  cursorConversionProperties
  envelopeConstructionProperties
  dlqPayloadProperties

-- | Property tests for MessageId conversion
messageIdConversionProperties :: Spec
messageIdConversionProperties = describe "MessageId conversion properties" $ do
  it "roundtrips all Int64 values" $ property $ \(n :: Int64) ->
    let pgmqId = Pgmq.MessageId n
        shibuyaId = messageIdToShibuya pgmqId
     in messageIdToPgmq shibuyaId === Just pgmqId

  it "messageIdToShibuya is injective" $ property $ \(n1 :: Int64) (n2 :: Int64) ->
    n1 /= n2 ==>
      messageIdToShibuya (Pgmq.MessageId n1)
        /= messageIdToShibuya (Pgmq.MessageId n2)

-- | Property tests for Cursor conversion
cursorConversionProperties :: Spec
cursorConversionProperties = describe "Cursor conversion properties" $ do
  it "preserves value for positive Int64" $ property $ \(Positive n :: Positive Int64) ->
    let cursor = pgmqMessageIdToCursor (Pgmq.MessageId n)
     in case cursor of
          CursorInt i -> i === fromIntegral n
          _ -> property False

-- | Property tests for Envelope construction
envelopeConstructionProperties :: Spec
envelopeConstructionProperties = describe "Envelope construction properties" $ do
  it "preserves messageId" $ property $ \(n :: Int64) ->
    let msg = mkTestMessage n
        Envelope {messageId = envMsgId} = pgmqMessageToEnvelope msg
     in envMsgId === messageIdToShibuya (Pgmq.MessageId n)

  it "always sets cursor to Just" $ property $ \(n :: Int64) ->
    let msg = mkTestMessage n
        Envelope {cursor = envCursor} = pgmqMessageToEnvelope msg
     in isJust envCursor === True

  it "always sets enqueuedAt to Just" $ property $ \(n :: Int64) ->
    let msg = mkTestMessage n
        Envelope {enqueuedAt = envEnqueuedAt} = pgmqMessageToEnvelope msg
     in isJust envEnqueuedAt === True

-- | Property tests for DLQ payload
dlqPayloadProperties :: Spec
dlqPayloadProperties = describe "DLQ payload properties" $ do
  it "always includes original_message key" $ property $ \(reason :: DeadLetterReason) (includeMeta :: Bool) ->
    let msg = mkTestMessage 1
        Pgmq.MessageBody payload = mkDlqPayload msg reason includeMeta
     in case payload of
          Object obj -> KeyMap.member "original_message" obj === True
          _ -> property False

  it "always includes dead_letter_reason key" $ property $ \(reason :: DeadLetterReason) (includeMeta :: Bool) ->
    let msg = mkTestMessage 1
        Pgmq.MessageBody payload = mkDlqPayload msg reason includeMeta
     in case payload of
          Object obj -> KeyMap.member "dead_letter_reason" obj === True
          _ -> property False

  it "metadata keys present iff includeMeta is True" $ property $ \(includeMeta :: Bool) ->
    let msg = mkTestMessage 1
        Pgmq.MessageBody payload = mkDlqPayload msg MaxRetriesExceeded includeMeta
     in case payload of
          Object obj ->
            KeyMap.member "original_message_id" obj === includeMeta
          _ -> property False

-- | Helper to create a test message with a given messageId
mkTestMessage :: Int64 -> Pgmq.Message
mkTestMessage n =
  Pgmq.Message
    { messageId = Pgmq.MessageId n,
      visibilityTime = testTime,
      enqueuedAt = testTime,
      readCount = 1,
      body = Pgmq.MessageBody Null,
      headers = Nothing
    }
  where
    testTime = UTCTime (fromGregorian 2024 1 1) 0

-- | Arbitrary instance for DeadLetterReason
instance Arbitrary DeadLetterReason where
  arbitrary =
    oneof
      [ pure MaxRetriesExceeded,
        PoisonPill <$> arbitraryText,
        InvalidPayload <$> arbitraryText
      ]
    where
      arbitraryText :: Gen Text
      arbitraryText = Text.pack <$> arbitrary

  shrink MaxRetriesExceeded = []
  shrink (PoisonPill t) = MaxRetriesExceeded : [PoisonPill (Text.pack t') | t' <- shrink (Text.unpack t)]
  shrink (InvalidPayload t) = MaxRetriesExceeded : [InvalidPayload (Text.pack t') | t' <- shrink (Text.unpack t)]
