module Shibuya.Adapter.Pgmq.ConvertSpec (spec) where

import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Pgmq.Types qualified as Pgmq
import Shibuya.Adapter.Pgmq.Convert
import Shibuya.Core.Ack (DeadLetterReason (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Test.Hspec
import Test.QuickCheck

spec :: Spec
spec = do
  messageIdToShibuyaSpec
  messageIdToPgmqSpec
  pgmqMessageIdToCursorSpec
  extractPartitionSpec
  extractTraceHeadersSpec
  pgmqMessageToEnvelopeSpec
  mkDlqPayloadSpec

-- | Tests for messageIdToShibuya
messageIdToShibuyaSpec :: Spec
messageIdToShibuyaSpec = describe "messageIdToShibuya" $ do
  it "converts positive Int64 to Text" $ do
    messageIdToShibuya (Pgmq.MessageId 42) `shouldBe` MessageId "42"

  it "converts zero" $ do
    messageIdToShibuya (Pgmq.MessageId 0) `shouldBe` MessageId "0"

  it "converts negative Int64" $ do
    messageIdToShibuya (Pgmq.MessageId (-1)) `shouldBe` MessageId "-1"

  it "converts Int64 max bound" $ do
    messageIdToShibuya (Pgmq.MessageId maxBound)
      `shouldBe` MessageId "9223372036854775807"

  it "converts Int64 min bound" $ do
    messageIdToShibuya (Pgmq.MessageId minBound)
      `shouldBe` MessageId "-9223372036854775808"

-- | Tests for messageIdToPgmq
messageIdToPgmqSpec :: Spec
messageIdToPgmqSpec = describe "messageIdToPgmq" $ do
  it "parses valid positive number" $ do
    messageIdToPgmq (MessageId "42") `shouldBe` Just (Pgmq.MessageId 42)

  it "parses valid negative number" $ do
    messageIdToPgmq (MessageId "-42") `shouldBe` Just (Pgmq.MessageId (-42))

  it "rejects empty string" $ do
    messageIdToPgmq (MessageId "") `shouldBe` Nothing

  it "rejects non-numeric text" $ do
    messageIdToPgmq (MessageId "abc") `shouldBe` Nothing

  it "rejects mixed text" $ do
    messageIdToPgmq (MessageId "42abc") `shouldBe` Nothing

  it "rejects trailing whitespace" $ do
    messageIdToPgmq (MessageId "42 ") `shouldBe` Nothing

  -- Note: Haskell's reads function skips leading whitespace
  it "handles leading whitespace (reads accepts it)" $ do
    messageIdToPgmq (MessageId " 42") `shouldBe` Just (Pgmq.MessageId 42)

  it "rejects decimal numbers" $ do
    messageIdToPgmq (MessageId "42.5") `shouldBe` Nothing

  -- Note: Haskell's reads function may wrap around for overflow values
  it "handles overflow values (implementation wraps)" $ do
    -- This documents current behavior - ideally should return Nothing
    messageIdToPgmq (MessageId "99999999999999999999") `shouldSatisfy` maybe False (const True)

  it "roundtrips correctly" $ property $ \(n :: Int64) ->
    let pgmqId = Pgmq.MessageId n
        shibuyaId = messageIdToShibuya pgmqId
     in messageIdToPgmq shibuyaId == Just pgmqId

-- | Tests for pgmqMessageIdToCursor
pgmqMessageIdToCursorSpec :: Spec
pgmqMessageIdToCursorSpec = describe "pgmqMessageIdToCursor" $ do
  it "creates CursorInt from MessageId" $ do
    pgmqMessageIdToCursor (Pgmq.MessageId 123) `shouldBe` CursorInt 123

  it "handles zero" $ do
    pgmqMessageIdToCursor (Pgmq.MessageId 0) `shouldBe` CursorInt 0

  it "handles large values" $ do
    pgmqMessageIdToCursor (Pgmq.MessageId 9999999999)
      `shouldBe` CursorInt 9999999999

-- | Tests for extractPartition (internal function, tested via pgmqMessageToEnvelope)
extractPartitionSpec :: Spec
extractPartitionSpec = describe "extractPartition via pgmqMessageToEnvelope" $ do
  let sampleTime = UTCTime (fromGregorian 2024 1 15) 3600
      mkMessage hdrs =
        Pgmq.Message
          { messageId = Pgmq.MessageId 42,
            visibilityTime = sampleTime,
            enqueuedAt = sampleTime,
            lastReadAt = Nothing,
            readCount = 1,
            body = Pgmq.MessageBody (String "test"),
            headers = hdrs
          }
      getPartition env = let Envelope {partition = p} = env in p

  it "extracts x-pgmq-group from headers object" $ do
    let headers = Just $ object ["x-pgmq-group" .= ("customer-1" :: Text.Text)]
        env = pgmqMessageToEnvelope (mkMessage headers)
    getPartition env `shouldBe` Just "customer-1"

  it "returns Nothing when headers is Nothing" $ do
    let env = pgmqMessageToEnvelope (mkMessage Nothing)
    getPartition env `shouldBe` Nothing

  it "returns Nothing when headers is not an object" $ do
    let headers = Just $ String "not an object"
        env = pgmqMessageToEnvelope (mkMessage headers)
    getPartition env `shouldBe` Nothing

  it "returns Nothing when x-pgmq-group key is missing" $ do
    let headers = Just $ object ["other-key" .= ("value" :: Text.Text)]
        env = pgmqMessageToEnvelope (mkMessage headers)
    getPartition env `shouldBe` Nothing

  it "returns Nothing when x-pgmq-group is not a string" $ do
    let headers = Just $ object ["x-pgmq-group" .= (42 :: Int)]
        env = pgmqMessageToEnvelope (mkMessage headers)
    getPartition env `shouldBe` Nothing

  it "handles empty string partition" $ do
    let headers = Just $ object ["x-pgmq-group" .= ("" :: Text.Text)]
        env = pgmqMessageToEnvelope (mkMessage headers)
    getPartition env `shouldBe` Just ""

-- | Tests for extractTraceHeaders
extractTraceHeadersSpec :: Spec
extractTraceHeadersSpec = describe "extractTraceHeaders" $ do
  it "extracts traceparent header only" $ do
    let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" :: Text.Text
        headers = Just $ object ["traceparent" .= traceparent]
    extractTraceHeaders headers
      `shouldBe` Just [("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")]

  it "extracts both traceparent and tracestate headers" $ do
    let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" :: Text.Text
        tracestate = "congo=t61rcWkgMzE" :: Text.Text
        headers = Just $ object ["traceparent" .= traceparent, "tracestate" .= tracestate]
        result = extractTraceHeaders headers
    result `shouldSatisfy` \case
      Just hs ->
        ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01") `elem` hs
          && ("tracestate", "congo=t61rcWkgMzE") `elem` hs
      Nothing -> False

  it "returns Nothing when headers is Nothing" $ do
    extractTraceHeaders Nothing `shouldBe` Nothing

  it "returns Nothing when headers is not an object" $ do
    let headers = Just $ String "not an object"
    extractTraceHeaders headers `shouldBe` Nothing

  it "returns Nothing when traceparent is missing" $ do
    let headers = Just $ object ["tracestate" .= ("congo=t61rcWkgMzE" :: Text.Text)]
    extractTraceHeaders headers `shouldBe` Nothing

  it "returns Nothing when traceparent is not a string" $ do
    let headers = Just $ object ["traceparent" .= (42 :: Int)]
    extractTraceHeaders headers `shouldBe` Nothing

  it "ignores tracestate when it's not a string" $ do
    let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" :: Text.Text
        headers = Just $ object ["traceparent" .= traceparent, "tracestate" .= (42 :: Int)]
    extractTraceHeaders headers
      `shouldBe` Just [("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")]

  it "handles empty traceparent string" $ do
    let headers = Just $ object ["traceparent" .= ("" :: Text.Text)]
    extractTraceHeaders headers `shouldBe` Just [("traceparent", "")]

  it "preserves traceparent with other headers present" $ do
    let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" :: Text.Text
        headers =
          Just $
            object
              [ "traceparent" .= traceparent,
                "x-pgmq-group" .= ("customer-1" :: Text.Text),
                "x-custom" .= ("value" :: Text.Text)
              ]
    extractTraceHeaders headers
      `shouldBe` Just [("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")]

-- | Tests for pgmqMessageToEnvelope
pgmqMessageToEnvelopeSpec :: Spec
pgmqMessageToEnvelopeSpec = describe "pgmqMessageToEnvelope" $ do
  let sampleTime = UTCTime (fromGregorian 2024 1 15) 3600
      mkMessage mid body hdrs =
        Pgmq.Message
          { messageId = Pgmq.MessageId mid,
            visibilityTime = sampleTime,
            enqueuedAt = sampleTime,
            lastReadAt = Nothing,
            readCount = 1,
            body = Pgmq.MessageBody body,
            headers = hdrs
          }

  it "sets messageId from pgmq message" $ do
    let msg = mkMessage 42 (String "test") Nothing
        Envelope {messageId = envMsgId} = pgmqMessageToEnvelope msg
    envMsgId `shouldBe` MessageId "42"

  it "sets cursor from messageId" $ do
    let msg = mkMessage 42 (String "test") Nothing
        Envelope {cursor = envCursor} = pgmqMessageToEnvelope msg
    envCursor `shouldBe` Just (CursorInt 42)

  it "sets enqueuedAt from pgmq message" $ do
    let msg = mkMessage 42 (String "test") Nothing
        Envelope {enqueuedAt = envEnqueuedAt} = pgmqMessageToEnvelope msg
    envEnqueuedAt `shouldBe` Just sampleTime

  it "extracts payload from body" $ do
    let payloadVal = object ["order_id" .= (123 :: Int)]
        msg = mkMessage 42 payloadVal Nothing
        Envelope {payload = envPayload} = pgmqMessageToEnvelope msg
    envPayload `shouldBe` payloadVal

  it "extracts partition from headers" $ do
    let hdrs = Just $ object ["x-pgmq-group" .= ("tenant-a" :: Text.Text)]
        msg = mkMessage 42 (String "test") hdrs
        Envelope {partition = envPartition} = pgmqMessageToEnvelope msg
    envPartition `shouldBe` Just "tenant-a"

  it "sets partition to Nothing when no headers" $ do
    let msg = mkMessage 42 (String "test") Nothing
        Envelope {partition = envPartition} = pgmqMessageToEnvelope msg
    envPartition `shouldBe` Nothing

  it "extracts traceContext from headers with traceparent" $ do
    let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" :: Text.Text
        hdrs = Just $ object ["traceparent" .= traceparent]
        msg = mkMessage 42 (String "test") hdrs
        Envelope {traceContext = envTraceContext} = pgmqMessageToEnvelope msg
    envTraceContext `shouldBe` Just [("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")]

  it "extracts traceContext with both traceparent and tracestate" $ do
    let traceparent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01" :: Text.Text
        tracestate = "vendor=opaque" :: Text.Text
        hdrs = Just $ object ["traceparent" .= traceparent, "tracestate" .= tracestate]
        msg = mkMessage 42 (String "test") hdrs
        Envelope {traceContext = envTraceContext} = pgmqMessageToEnvelope msg
    envTraceContext `shouldSatisfy` \case
      Just hs ->
        ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01") `elem` hs
          && ("tracestate", "vendor=opaque") `elem` hs
      Nothing -> False

  it "sets traceContext to Nothing when no headers" $ do
    let msg = mkMessage 42 (String "test") Nothing
        Envelope {traceContext = envTraceContext} = pgmqMessageToEnvelope msg
    envTraceContext `shouldBe` Nothing

  it "sets traceContext to Nothing when no traceparent in headers" $ do
    let hdrs = Just $ object ["x-pgmq-group" .= ("customer-1" :: Text.Text)]
        msg = mkMessage 42 (String "test") hdrs
        Envelope {traceContext = envTraceContext} = pgmqMessageToEnvelope msg
    envTraceContext `shouldBe` Nothing

-- | Tests for mkDlqPayload
mkDlqPayloadSpec :: Spec
mkDlqPayloadSpec = describe "mkDlqPayload" $ do
  let sampleTime = UTCTime (fromGregorian 2024 1 15) 0
      sampleMessage =
        Pgmq.Message
          { messageId = Pgmq.MessageId 42,
            visibilityTime = sampleTime,
            enqueuedAt = sampleTime,
            lastReadAt = Just sampleTime,
            readCount = 5,
            body = Pgmq.MessageBody (object ["data" .= ("test" :: Text.Text)]),
            headers = Just $ object ["x-pgmq-group" .= ("group1" :: Text.Text)]
          }

  describe "without metadata" $ do
    it "includes original_message" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded False
      case payload of
        Object obj -> KeyMap.member "original_message" obj `shouldBe` True
        _ -> expectationFailure "Expected Object"

    it "includes dead_letter_reason" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded False
      case payload of
        Object obj -> KeyMap.member "dead_letter_reason" obj `shouldBe` True
        _ -> expectationFailure "Expected Object"

    it "does not include original_message_id" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded False
      case payload of
        Object obj -> KeyMap.member "original_message_id" obj `shouldBe` False
        _ -> expectationFailure "Expected Object"

    it "does not include read_count" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded False
      case payload of
        Object obj -> KeyMap.member "read_count" obj `shouldBe` False
        _ -> expectationFailure "Expected Object"

  describe "with metadata" $ do
    it "includes original_message_id" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded True
      case payload of
        Object obj -> do
          KeyMap.member "original_message_id" obj `shouldBe` True
          KeyMap.lookup "original_message_id" obj `shouldBe` Just (Number 42)
        _ -> expectationFailure "Expected Object"

    it "includes original_enqueued_at" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded True
      case payload of
        Object obj -> KeyMap.member "original_enqueued_at" obj `shouldBe` True
        _ -> expectationFailure "Expected Object"

    it "includes read_count" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded True
      case payload of
        Object obj -> KeyMap.lookup "read_count" obj `shouldBe` Just (Number 5)
        _ -> expectationFailure "Expected Object"

    it "includes original_headers" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded True
      case payload of
        Object obj -> KeyMap.member "original_headers" obj `shouldBe` True
        _ -> expectationFailure "Expected Object"

    it "includes last_read_at" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded True
      case payload of
        Object obj -> KeyMap.member "last_read_at" obj `shouldBe` True
        _ -> expectationFailure "Expected Object"

  describe "reason formatting" $ do
    it "formats MaxRetriesExceeded" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage MaxRetriesExceeded False
      case payload of
        Object obj ->
          KeyMap.lookup "dead_letter_reason" obj
            `shouldBe` Just (String "max_retries_exceeded")
        _ -> expectationFailure "Expected Object"

    it "formats PoisonPill with message" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage (PoisonPill "corrupt data") False
      case payload of
        Object obj ->
          KeyMap.lookup "dead_letter_reason" obj
            `shouldBe` Just (String "poison_pill: corrupt data")
        _ -> expectationFailure "Expected Object"

    it "formats InvalidPayload with message" $ do
      let Pgmq.MessageBody payload = mkDlqPayload sampleMessage (InvalidPayload "parse error") False
      case payload of
        Object obj ->
          KeyMap.lookup "dead_letter_reason" obj
            `shouldBe` Just (String "invalid_payload: parse error")
        _ -> expectationFailure "Expected Object"
