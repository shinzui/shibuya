# PGMQ Adapter Test Plan

This document provides a comprehensive test plan for the shibuya-pgmq-adapter, covering unit tests, property tests, integration tests, and performance benchmarks.

## Table of Contents

- [Test Categories Overview](#test-categories-overview)
- [Unit Tests](#unit-tests)
- [Property-Based Tests](#property-based-tests)
- [Integration Tests](#integration-tests)
- [End-to-End Tests](#end-to-end-tests)
- [Performance Tests](#performance-tests)
- [Test Infrastructure](#test-infrastructure)
- [Test Matrix](#test-matrix)

## Test Categories Overview

| Category | Scope | Dependencies | Runtime | Tag |
|----------|-------|--------------|---------|-----|
| Unit | Pure functions, type conversions | None | Fast (< 1s) | - |
| Property | Invariants, roundtrips | QuickCheck | Fast (< 5s) | - |
| Integration | pgmq operations, streams | PostgreSQL + pgmq | Medium (< 30s) | `integration` |
| End-to-End | Full Shibuya + pgmq | PostgreSQL + pgmq | Slow (< 2min) | `e2e`, `slow` |
| Performance | Throughput, latency | PostgreSQL + pgmq | Variable | `benchmark`, `slow` |

## Running Tests

### Quick Tests (No Database Required)

Run only unit and property tests:

```bash
cabal test shibuya-pgmq-adapter-test --test-option='--pattern=!/integration/ && !/e2e/ && !/benchmark/'
```

Or using the Tasty pattern:

```bash
cabal test shibuya-pgmq-adapter-test --test-option='-p' --test-option='!/Slow/'
```

### Integration Tests

Run integration tests (requires tmp-postgres):

```bash
cabal test shibuya-pgmq-adapter-test --test-option='-p' --test-option='/Integration/'
```

### All Tests

Run the full test suite:

```bash
cabal test shibuya-pgmq-adapter-test
```

### Excluding Slow Tests

Skip e2e and benchmark tests for faster CI:

```bash
cabal test shibuya-pgmq-adapter-test --test-option='-p' --test-option='!/Slow/'
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `PGMQ_TEST_SKIP_SLOW` | Set to `1` to skip slow tests | - |
| `PGMQ_TEST_SKIP_DB` | Set to `1` to skip all database tests | - |

## Unit Tests

### 1. Type Conversion Tests (Convert.hs)

**File**: `test/Shibuya/Adapter/Pgmq/ConvertSpec.hs`

#### 1.1 MessageId Conversion

```haskell
describe "messageIdToShibuya" $ do
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
```

#### 1.2 MessageId Parsing

```haskell
describe "messageIdToPgmq" $ do
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

  it "rejects leading whitespace" $ do
    messageIdToPgmq (MessageId " 42") `shouldBe` Nothing

  it "rejects decimal numbers" $ do
    messageIdToPgmq (MessageId "42.5") `shouldBe` Nothing

  it "rejects overflow values" $ do
    messageIdToPgmq (MessageId "99999999999999999999") `shouldBe` Nothing
```

#### 1.3 Cursor Conversion

```haskell
describe "pgmqMessageIdToCursor" $ do
  it "creates CursorInt from MessageId" $ do
    pgmqMessageIdToCursor (Pgmq.MessageId 123) `shouldBe` CursorInt 123

  it "handles zero" $ do
    pgmqMessageIdToCursor (Pgmq.MessageId 0) `shouldBe` CursorInt 0

  it "handles large values" $ do
    pgmqMessageIdToCursor (Pgmq.MessageId 9999999999)
      `shouldBe` CursorInt 9999999999
```

#### 1.4 Partition Extraction

```haskell
describe "extractPartition" $ do
  it "extracts x-pgmq-group from headers object" $ do
    let headers = Just $ object ["x-pgmq-group" .= ("customer-1" :: Text)]
    extractPartition headers `shouldBe` Just "customer-1"

  it "returns Nothing when headers is Nothing" $ do
    extractPartition Nothing `shouldBe` Nothing

  it "returns Nothing when headers is not an object" $ do
    extractPartition (Just $ String "not an object") `shouldBe` Nothing

  it "returns Nothing when x-pgmq-group key is missing" $ do
    let headers = Just $ object ["other-key" .= ("value" :: Text)]
    extractPartition headers `shouldBe` Nothing

  it "returns Nothing when x-pgmq-group is not a string" $ do
    let headers = Just $ object ["x-pgmq-group" .= (42 :: Int)]
    extractPartition headers `shouldBe` Nothing

  it "handles empty string partition" $ do
    let headers = Just $ object ["x-pgmq-group" .= ("" :: Text)]
    extractPartition headers `shouldBe` Just ""
```

#### 1.5 Envelope Construction

```haskell
describe "pgmqMessageToEnvelope" $ do
  let sampleTime = UTCTime (fromGregorian 2024 1 15) 3600
      mkMessage mid body hdrs = Pgmq.Message
        { messageId = Pgmq.MessageId mid,
          visibilityTime = sampleTime,
          enqueuedAt = sampleTime,
          readCount = 1,
          body = Pgmq.MessageBody body,
          headers = hdrs
        }

  it "sets messageId from pgmq message" $ do
    let msg = mkMessage 42 (String "test") Nothing
        env = pgmqMessageToEnvelope msg
    env.messageId `shouldBe` MessageId "42"

  it "sets cursor from messageId" $ do
    let msg = mkMessage 42 (String "test") Nothing
        env = pgmqMessageToEnvelope msg
    env.cursor `shouldBe` Just (CursorInt 42)

  it "sets enqueuedAt from pgmq message" $ do
    let msg = mkMessage 42 (String "test") Nothing
        env = pgmqMessageToEnvelope msg
    env.enqueuedAt `shouldBe` Just sampleTime

  it "extracts payload from body" $ do
    let payload = object ["order_id" .= (123 :: Int)]
        msg = mkMessage 42 payload Nothing
        env = pgmqMessageToEnvelope msg
    env.payload `shouldBe` payload

  it "extracts partition from headers" $ do
    let hdrs = Just $ object ["x-pgmq-group" .= ("tenant-a" :: Text)]
        msg = mkMessage 42 (String "test") hdrs
        env = pgmqMessageToEnvelope msg
    env.partition `shouldBe` Just "tenant-a"

  it "sets partition to Nothing when no headers" $ do
    let msg = mkMessage 42 (String "test") Nothing
        env = pgmqMessageToEnvelope msg
    env.partition `shouldBe` Nothing
```

#### 1.6 DLQ Payload Construction

```haskell
describe "mkDlqPayload" $ do
  let sampleTime = UTCTime (fromGregorian 2024 1 15) 0
      sampleMessage = Pgmq.Message
        { messageId = Pgmq.MessageId 42,
          visibilityTime = sampleTime,
          enqueuedAt = sampleTime,
          readCount = 5,
          body = Pgmq.MessageBody (object ["data" .= ("test" :: Text)]),
          headers = Just $ object ["x-pgmq-group" .= ("group1" :: Text)]
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
```

### 2. Configuration Tests (Config.hs)

**File**: `test/Shibuya/Adapter/Pgmq/ConfigSpec.hs`

```haskell
describe "defaultConfig" $ do
  let Right queueName = parseQueueName "test-queue"
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

describe "defaultPollingConfig" $ do
  it "is StandardPolling" $ do
    case defaultPollingConfig of
      StandardPolling _ -> pure ()
      _ -> expectationFailure "Expected StandardPolling"

  it "has 1 second interval" $ do
    case defaultPollingConfig of
      StandardPolling interval -> interval `shouldBe` 1
      _ -> expectationFailure "Expected StandardPolling"

describe "defaultPrefetchConfig" $ do
  it "has bufferSize of 4" $ do
    defaultPrefetchConfig.bufferSize `shouldBe` 4
```

### 3. Internal Function Tests (Internal.hs)

**File**: `test/Shibuya/Adapter/Pgmq/InternalSpec.hs`

```haskell
describe "nominalToSeconds" $ do
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

describe "mkReadMessage" $ do
  let Right queueName = parseQueueName "test-queue"
      config = (defaultConfig queueName)
        { visibilityTimeout = 60,
          batchSize = 10
        }
      query = mkReadMessage config

  it "sets queueName from config" $ do
    query.queueName `shouldBe` queueName

  it "sets delay to visibilityTimeout" $ do
    query.delay `shouldBe` 60

  it "sets batchSize from config" $ do
    query.batchSize `shouldBe` Just 10

  it "sets conditional to Nothing" $ do
    query.conditional `shouldBe` Nothing

describe "mkReadWithPoll" $ do
  let Right queueName = parseQueueName "test-queue"
      config = (defaultConfig queueName)
        { visibilityTimeout = 60,
          batchSize = 10
        }
      query = mkReadWithPoll config 5 100

  it "sets maxPollSeconds from parameter" $ do
    query.maxPollSeconds `shouldBe` 5

  it "sets pollIntervalMs from parameter" $ do
    query.pollIntervalMs `shouldBe` 100

describe "mkReadGrouped" $ do
  let Right queueName = parseQueueName "test-queue"
      config = (defaultConfig queueName)
        { visibilityTimeout = 60,
          batchSize = 20
        }
      query = mkReadGrouped config

  it "sets queueName from config" $ do
    query.queueName `shouldBe` queueName

  it "sets visibilityTimeout from config" $ do
    query.visibilityTimeout `shouldBe` 60

  it "sets qty to batchSize" $ do
    query.qty `shouldBe` 20
```

## Property-Based Tests

**File**: `test/Shibuya/Adapter/Pgmq/PropertySpec.hs`

### 1. MessageId Roundtrip

```haskell
describe "MessageId conversion properties" $ do
  it "roundtrips all Int64 values" $ property $ \(n :: Int64) ->
    let pgmqId = Pgmq.MessageId n
        shibuyaId = messageIdToShibuya pgmqId
     in messageIdToPgmq shibuyaId === Just pgmqId

  it "messageIdToShibuya is injective" $ property $ \(n1 :: Int64) (n2 :: Int64) ->
    n1 /= n2 ==>
      messageIdToShibuya (Pgmq.MessageId n1)
        /= messageIdToShibuya (Pgmq.MessageId n2)
```

### 2. Cursor Conversion

```haskell
describe "Cursor conversion properties" $ do
  it "preserves value for positive Int64" $ property $ \(Positive n :: Positive Int64) ->
    let cursor = pgmqMessageIdToCursor (Pgmq.MessageId n)
     in case cursor of
          CursorInt i -> i === fromIntegral n
          _ -> property False
```

### 3. Envelope Construction

```haskell
describe "Envelope construction properties" $ do
  it "preserves messageId" $ property $ \(n :: Int64) ->
    let msg = mkTestMessage n
        env = pgmqMessageToEnvelope msg
     in env.messageId === messageIdToShibuya (Pgmq.MessageId n)

  it "always sets cursor to Just" $ property $ \(n :: Int64) ->
    let msg = mkTestMessage n
        env = pgmqMessageToEnvelope msg
     in isJust env.cursor === True

  it "always sets enqueuedAt to Just" $ property $ \(n :: Int64) ->
    let msg = mkTestMessage n
        env = pgmqMessageToEnvelope msg
     in isJust env.enqueuedAt === True

mkTestMessage :: Int64 -> Pgmq.Message
mkTestMessage n = Pgmq.Message
  { messageId = Pgmq.MessageId n,
    visibilityTime = testTime,
    enqueuedAt = testTime,
    readCount = 1,
    body = Pgmq.MessageBody Null,
    headers = Nothing
  }
```

### 4. DLQ Payload Properties

```haskell
describe "DLQ payload properties" $ do
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

-- Arbitrary instance for DeadLetterReason
instance Arbitrary DeadLetterReason where
  arbitrary = oneof
    [ pure MaxRetriesExceeded,
      PoisonPill <$> arbitrary,
      InvalidPayload <$> arbitrary
    ]
```

## Integration Tests

Integration tests use tmp-postgres to create a temporary PostgreSQL instance with the pgmq extension. See [Test Infrastructure](#test-infrastructure) for setup details.

**File**: `test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs`

**Run**: `cabal test --test-option='-p' --test-option='/Integration/'`

**Skip**: Set `PGMQ_TEST_SKIP_DB=1` or use pattern `!/Integration/`

### 1. Basic Message Processing

```haskell
describe "Basic message processing" $ do
  it "processes a single message and deletes it" $ withTestFixture $ \fixture -> do
    -- Enqueue a message
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    -- Create adapter and process
    processedRef <- newIORef Nothing
    runEff . runPgmq fixture.pool $ do
      let config = defaultConfig fixture.queueName
      adapter <- pgmqAdapter config

      -- Take one message from stream
      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          liftIO $ writeIORef processedRef (Just ingested.envelope.payload)
          ingested.ack.finalize AckOk
        Nothing -> pure ()

    -- Verify message was processed
    processed <- readIORef processedRef
    processed `shouldBe` Just (String "test")

    -- Verify queue is empty
    count <- runEff . runPgmq fixture.pool $ getQueueLength fixture.queueName
    count `shouldBe` 0

  it "processes multiple messages in order" $ withTestFixture $ \fixture -> do
    -- Enqueue 5 messages
    runEff . runPgmq fixture.pool $ do
      forM_ [1..5 :: Int] $ \i ->
        sendMessage $ SendMessage fixture.queueName
          (Pgmq.MessageBody (object ["order" .= i])) Nothing

    -- Process all messages
    processedRef <- newIORef []
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { batchSize = 10 }
      adapter <- pgmqAdapter config

      Stream.fold (Fold.drainMapM $ \ingested -> do
        liftIO $ modifyIORef' processedRef (ingested.envelope.payload :)
        ingested.ack.finalize AckOk
      ) $ Stream.take 5 adapter.source

    -- Verify order
    processed <- reverse <$> readIORef processedRef
    let orders = [p ^? key "order" . _Integer | p <- processed]
    orders `shouldBe` [Just 1, Just 2, Just 3, Just 4, Just 5]
```

### 2. Visibility Timeout Tests

```haskell
describe "Visibility timeout" $ do
  it "message is invisible during processing" $ withTestFixture $ \fixture -> do
    -- Enqueue a message
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    -- Read message but don't ack
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { visibilityTimeout = 10 }
      adapter <- pgmqAdapter config

      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          -- Try to read again - should get nothing
          let config2 = config
          adapter2 <- pgmqAdapter config2
          mSecond <- Stream.uncons $ Stream.take 1 adapter2.source
          liftIO $ mSecond `shouldBe` Nothing

          -- Ack the first message
          ingested.ack.finalize AckOk
        Nothing -> liftIO $ expectationFailure "Expected message"

  it "message reappears after visibility timeout" $ withTestFixture $ \fixture -> do
    -- Enqueue a message
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    -- Read message with short VT, don't ack
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { visibilityTimeout = 1 }
      msgs <- readMessage $ mkReadMessage config
      liftIO $ Vector.length msgs `shouldBe` 1

    -- Wait for VT to expire
    threadDelay 1500000  -- 1.5 seconds

    -- Message should be visible again
    runEff . runPgmq fixture.pool $ do
      msgs <- readMessage $ ReadMessage fixture.queueName 30 (Just 1) Nothing
      liftIO $ Vector.length msgs `shouldBe` 1
```

### 3. Retry and Dead-Letter Tests

```haskell
describe "Retry handling" $ do
  it "AckRetry extends visibility timeout" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { visibilityTimeout = 1 }
      adapter <- pgmqAdapter config

      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          -- Retry with 5 second delay
          ingested.ack.finalize (AckRetry (RetryDelay 5))
        Nothing -> pure ()

    -- Message should not be visible yet (VT extended to 5s)
    threadDelay 2000000  -- 2 seconds
    count <- runEff . runPgmq fixture.pool $ do
      msgs <- readMessage $ ReadMessage fixture.queueName 30 (Just 1) Nothing
      pure $ Vector.length msgs
    count `shouldBe` 0

    -- After 5 seconds total, message should be visible
    threadDelay 4000000  -- 4 more seconds
    count2 <- runEff . runPgmq fixture.pool $ do
      msgs <- readMessage $ ReadMessage fixture.queueName 30 (Just 1) Nothing
      pure $ Vector.length msgs
    count2 `shouldBe` 1

  it "auto dead-letters when maxRetries exceeded" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    -- Simulate 4 reads (maxRetries = 3, so 4th read triggers auto-DLQ)
    forM_ [1..3 :: Int] $ \_ -> do
      runEff . runPgmq fixture.pool $ do
        msgs <- readMessage $ ReadMessage fixture.queueName 1 (Just 1) Nothing
        pure ()
      threadDelay 1500000  -- Wait for VT to expire

    -- 4th read should auto-DLQ
    processedRef <- newIORef False
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName)
            { maxRetries = 3,
              deadLetterConfig = Just DeadLetterConfig
                { dlqQueueName = fixture.dlqName,
                  includeMetadata = True
                }
            }
      adapter <- pgmqAdapter config

      -- Stream should yield nothing (message auto-DLQ'd)
      mIngested <- Stream.uncons $ Stream.take 1 adapter.source
      case mIngested of
        Just (ingested, _) -> liftIO $ writeIORef processedRef True
        Nothing -> pure ()

    processed <- readIORef processedRef
    processed `shouldBe` False

    -- Check DLQ has the message
    dlqCount <- runEff . runPgmq fixture.pool $ do
      msgs <- readMessage $ ReadMessage fixture.dlqName 30 (Just 1) Nothing
      pure $ Vector.length msgs
    dlqCount `shouldBe` 1

  it "AckDeadLetter sends to DLQ with metadata" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName
        (Pgmq.MessageBody (object ["data" .= ("important" :: Text)])) Nothing

    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName)
            { deadLetterConfig = Just DeadLetterConfig
                { dlqQueueName = fixture.dlqName,
                  includeMetadata = True
                }
            }
      adapter <- pgmqAdapter config

      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          ingested.ack.finalize (AckDeadLetter (PoisonPill "corrupt"))
        Nothing -> pure ()

    -- Check DLQ message content
    dlqMsg <- runEff . runPgmq fixture.pool $ do
      msgs <- readMessage $ ReadMessage fixture.dlqName 30 (Just 1) Nothing
      pure $ Vector.head msgs

    let Pgmq.MessageBody payload = dlqMsg.body
    case payload of
      Object obj -> do
        KeyMap.lookup "dead_letter_reason" obj
          `shouldBe` Just (String "poison_pill: corrupt")
        KeyMap.member "original_message_id" obj `shouldBe` True
        KeyMap.member "read_count" obj `shouldBe` True
      _ -> expectationFailure "Expected Object"

  it "AckDeadLetter archives when no DLQ configured" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { deadLetterConfig = Nothing }
      adapter <- pgmqAdapter config

      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          ingested.ack.finalize (AckDeadLetter MaxRetriesExceeded)
        Nothing -> pure ()

    -- Queue should be empty
    count <- runEff . runPgmq fixture.pool $ getQueueLength fixture.queueName
    count `shouldBe` 0

    -- Archive should have the message
    archiveCount <- runEff . runPgmq fixture.pool $ getArchiveLength fixture.queueName
    archiveCount `shouldBe` 1
```

### 4. Lease Extension Tests

```haskell
describe "Lease extension" $ do
  it "leaseExtend extends visibility timeout" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { visibilityTimeout = 2 }
      adapter <- pgmqAdapter config

      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          -- Extend lease by 10 seconds
          case ingested.lease of
            Just lease -> lease.leaseExtend 10
            Nothing -> liftIO $ expectationFailure "Expected lease"

          -- Wait 3 seconds (past original VT)
          liftIO $ threadDelay 3000000

          -- Message should still be invisible
          msgs <- readMessage $ ReadMessage fixture.queueName 30 (Just 1) Nothing
          liftIO $ Vector.length msgs `shouldBe` 0

          ingested.ack.finalize AckOk
        Nothing -> liftIO $ expectationFailure "Expected message"

  it "lease has correct leaseId" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    leaseIdRef <- newIORef Nothing
    runEff . runPgmq fixture.pool $ do
      let config = defaultConfig fixture.queueName
      adapter <- pgmqAdapter config

      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          case ingested.lease of
            Just lease -> liftIO $ writeIORef leaseIdRef (Just lease.leaseId)
            Nothing -> pure ()
          ingested.ack.finalize AckOk
        Nothing -> pure ()

    leaseId <- readIORef leaseIdRef
    -- leaseId should be a numeric string (message ID)
    case leaseId of
      Just lid -> Text.all isDigit lid `shouldBe` True
      Nothing -> expectationFailure "Expected leaseId"
```

### 5. FIFO Ordering Tests

```haskell
describe "FIFO ordering" $ do
  it "ThroughputOptimized fills batch from same group" $ withTestFixture $ \fixture -> do
    -- Enqueue messages in different groups
    runEff . runPgmq fixture.pool $ do
      forM_ [1..3 :: Int] $ \i ->
        sendMessageWithHeaders fixture.queueName
          (object ["group" .= ("A" :: Text), "seq" .= i])
          (object ["x-pgmq-group" .= ("A" :: Text)])
      forM_ [1..3 :: Int] $ \i ->
        sendMessageWithHeaders fixture.queueName
          (object ["group" .= ("B" :: Text), "seq" .= i])
          (object ["x-pgmq-group" .= ("B" :: Text)])

    -- Read with ThroughputOptimized
    processedRef <- newIORef []
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName)
            { batchSize = 3,
              fifoConfig = Just FifoConfig { readStrategy = ThroughputOptimized }
            }
      adapter <- pgmqAdapter config

      Stream.fold (Fold.drainMapM $ \ingested -> do
        liftIO $ modifyIORef' processedRef (ingested.envelope.partition :)
        ingested.ack.finalize AckOk
      ) $ Stream.take 3 adapter.source

    processed <- reverse <$> readIORef processedRef
    -- First batch should all be from same group
    processed `shouldSatisfy` allSame

  it "RoundRobin distributes across groups" $ withTestFixture $ \fixture -> do
    -- Enqueue messages in different groups
    runEff . runPgmq fixture.pool $ do
      forM_ [1..3 :: Int] $ \i ->
        sendMessageWithHeaders fixture.queueName
          (object ["group" .= ("A" :: Text), "seq" .= i])
          (object ["x-pgmq-group" .= ("A" :: Text)])
      forM_ [1..3 :: Int] $ \i ->
        sendMessageWithHeaders fixture.queueName
          (object ["group" .= ("B" :: Text), "seq" .= i])
          (object ["x-pgmq-group" .= ("B" :: Text)])

    -- Read with RoundRobin
    processedRef <- newIORef []
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName)
            { batchSize = 4,
              fifoConfig = Just FifoConfig { readStrategy = RoundRobin }
            }
      adapter <- pgmqAdapter config

      Stream.fold (Fold.drainMapM $ \ingested -> do
        liftIO $ modifyIORef' processedRef (ingested.envelope.partition :)
        ingested.ack.finalize AckOk
      ) $ Stream.take 4 adapter.source

    processed <- reverse <$> readIORef processedRef
    -- Should have messages from both groups
    let groups = catMaybes processed
    length (nub groups) `shouldBe` 2

allSame :: Eq a => [a] -> Bool
allSame [] = True
allSame (x:xs) = all (== x) xs
```

### 6. Polling Strategy Tests

```haskell
describe "Polling strategies" $ do
  describe "StandardPolling" $ do
    it "sleeps between empty polls" $ withTestFixture $ \fixture -> do
      -- Don't enqueue any messages
      startTime <- getCurrentTime

      runEff . runPgmq fixture.pool $ do
        let config = (defaultConfig fixture.queueName)
              { polling = StandardPolling { pollInterval = 0.5 }
              }
        adapter <- pgmqAdapter config

        -- Take 0 messages, but stream will poll twice
        Stream.fold Fold.drain $ Stream.take 0 adapter.source

      endTime <- getCurrentTime
      let elapsed = diffUTCTime endTime startTime
      -- At least one poll interval should have passed
      elapsed `shouldSatisfy` (< 1)  -- But not too long

  describe "LongPolling" $ do
    it "returns immediately when messages available" $ withTestFixture $ \fixture -> do
      runEff . runPgmq fixture.pool $ do
        sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

      startTime <- getCurrentTime

      runEff . runPgmq fixture.pool $ do
        let config = (defaultConfig fixture.queueName)
              { polling = LongPolling { maxPollSeconds = 10, pollIntervalMs = 100 }
              }
        adapter <- pgmqAdapter config

        mIngested <- Stream.uncons adapter.source
        case mIngested of
          Just (ingested, _) -> ingested.ack.finalize AckOk
          Nothing -> pure ()

      endTime <- getCurrentTime
      let elapsed = diffUTCTime endTime startTime
      -- Should return quickly, not wait 10 seconds
      elapsed `shouldSatisfy` (< 1)

    it "waits up to maxPollSeconds when queue empty" $ withTestFixture $ \fixture -> do
      startTime <- getCurrentTime

      runEff . runPgmq fixture.pool $ do
        let config = (defaultConfig fixture.queueName)
              { polling = LongPolling { maxPollSeconds = 1, pollIntervalMs = 100 }
              }
        adapter <- pgmqAdapter config

        -- Take 0 messages, triggers poll
        Stream.fold Fold.drain $ Stream.take 0 adapter.source

      endTime <- getCurrentTime
      let elapsed = diffUTCTime endTime startTime
      -- Should have waited approximately 1 second
      elapsed `shouldSatisfy` (>= 0.9)
      elapsed `shouldSatisfy` (< 2)
```

### 7. Batch Processing Tests

```haskell
describe "Batch processing" $ do
  it "processes all messages from batch" $ withTestFixture $ \fixture -> do
    -- Enqueue 10 messages
    runEff . runPgmq fixture.pool $ do
      forM_ [1..10 :: Int] $ \i ->
        sendMessage $ SendMessage fixture.queueName
          (Pgmq.MessageBody (object ["n" .= i])) Nothing

    processedRef <- newIORef (0 :: Int)
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { batchSize = 10 }
      adapter <- pgmqAdapter config

      Stream.fold (Fold.drainMapM $ \ingested -> do
        liftIO $ modifyIORef' processedRef (+ 1)
        ingested.ack.finalize AckOk
      ) $ Stream.take 10 adapter.source

    processed <- readIORef processedRef
    processed `shouldBe` 10

  it "no batch wastage - all messages in batch are used" $ withTestFixture $ \fixture -> do
    -- This test verifies the unfoldEach fix
    -- Enqueue 5 messages
    runEff . runPgmq fixture.pool $ do
      forM_ [1..5 :: Int] $ \i ->
        sendMessage $ SendMessage fixture.queueName
          (Pgmq.MessageBody (object ["n" .= i])) Nothing

    -- Track poll count vs message count
    pollCountRef <- newIORef (0 :: Int)
    msgCountRef <- newIORef (0 :: Int)

    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { batchSize = 5 }
      -- We can't easily count polls at this level, but we can verify all messages processed
      adapter <- pgmqAdapter config

      Stream.fold (Fold.drainMapM $ \ingested -> do
        liftIO $ modifyIORef' msgCountRef (+ 1)
        ingested.ack.finalize AckOk
      ) $ Stream.take 5 adapter.source

    msgCount <- readIORef msgCountRef
    msgCount `shouldBe` 5

    -- Queue should be empty
    remaining <- runEff . runPgmq fixture.pool $ getQueueLength fixture.queueName
    remaining `shouldBe` 0
```

### 8. Prefetch Tests

```haskell
describe "Prefetching" $ do
  it "prefetch reduces latency" $ withTestFixture $ \fixture -> do
    -- Enqueue messages
    runEff . runPgmq fixture.pool $ do
      forM_ [1..20 :: Int] $ \i ->
        sendMessage $ SendMessage fixture.queueName
          (Pgmq.MessageBody (object ["n" .= i])) Nothing

    -- Process without prefetch
    startWithout <- getCurrentTime
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName)
            { batchSize = 5,
              prefetchConfig = Nothing
            }
      adapter <- pgmqAdapter config
      Stream.fold (Fold.drainMapM $ \ingested -> do
        liftIO $ threadDelay 10000  -- 10ms processing
        ingested.ack.finalize AckOk
      ) $ Stream.take 10 adapter.source
    endWithout <- getCurrentTime

    -- Re-enqueue
    runEff . runPgmq fixture.pool $ do
      forM_ [1..20 :: Int] $ \i ->
        sendMessage $ SendMessage fixture.queueName
          (Pgmq.MessageBody (object ["n" .= i])) Nothing

    -- Process with prefetch
    startWith <- getCurrentTime
    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName)
            { batchSize = 5,
              prefetchConfig = Just PrefetchConfig { bufferSize = 4 }
            }
      adapter <- pgmqAdapter config
      Stream.fold (Fold.drainMapM $ \ingested -> do
        liftIO $ threadDelay 10000  -- 10ms processing
        ingested.ack.finalize AckOk
      ) $ Stream.take 10 adapter.source
    endWith <- getCurrentTime

    let timeWithout = diffUTCTime endWithout startWithout
        timeWith = diffUTCTime endWith startWith

    -- Prefetch should be faster (poll overlaps with processing)
    timeWith `shouldSatisfy` (< timeWithout)
```

### 9. Shutdown Tests

```haskell
describe "Shutdown handling" $ do
  it "shutdown stops yielding new messages" $ withTestFixture $ \fixture -> do
    -- Enqueue many messages
    runEff . runPgmq fixture.pool $ do
      forM_ [1..100 :: Int] $ \i ->
        sendMessage $ SendMessage fixture.queueName
          (Pgmq.MessageBody (object ["n" .= i])) Nothing

    processedRef <- newIORef (0 :: Int)
    runEff . runPgmq fixture.pool $ do
      let config = defaultConfig fixture.queueName
      adapter <- pgmqAdapter config

      -- Process some messages then shutdown
      Stream.fold (Fold.drainMapM $ \ingested -> do
        count <- liftIO $ readIORef processedRef
        liftIO $ modifyIORef' processedRef (+ 1)
        ingested.ack.finalize AckOk
        when (count >= 9) $ adapter.shutdown
      ) adapter.source

    processed <- readIORef processedRef
    -- Should have stopped after ~10 messages
    processed `shouldSatisfy` (< 20)
    processed `shouldSatisfy` (>= 10)

  it "in-flight message is acked before stream ends" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    ackedRef <- newIORef False
    runEff . runPgmq fixture.pool $ do
      let config = defaultConfig fixture.queueName
      adapter <- pgmqAdapter config

      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          adapter.shutdown
          -- Should still be able to ack
          ingested.ack.finalize AckOk
          liftIO $ writeIORef ackedRef True
        Nothing -> pure ()

    acked <- readIORef ackedRef
    acked `shouldBe` True

    -- Message should be deleted
    count <- runEff . runPgmq fixture.pool $ getQueueLength fixture.queueName
    count `shouldBe` 0
```

### 10. AckHalt Tests

```haskell
describe "AckHalt behavior" $ do
  it "AckHalt extends VT to 1 hour" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName (Pgmq.MessageBody (String "test")) Nothing

    -- Get original message to check VT later
    originalVT <- runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { visibilityTimeout = 30 }
      adapter <- pgmqAdapter config

      mIngested <- Stream.uncons adapter.source
      case mIngested of
        Just (ingested, _) -> do
          ingested.ack.finalize (AckHalt (HaltFatal "test halt"))
          -- Query message directly to check VT
          msgs <- readMessage $ ReadMessage fixture.queueName 7200 (Just 1) Nothing
          case Vector.uncons msgs of
            Just (msg, _) -> pure $ Just msg.visibilityTime
            Nothing -> pure Nothing
        Nothing -> pure Nothing

    -- VT should be ~1 hour in future
    now <- getCurrentTime
    case originalVT of
      Just vt -> do
        let diff = diffUTCTime vt now
        diff `shouldSatisfy` (> 3500)  -- At least ~58 minutes
        diff `shouldSatisfy` (< 3700)  -- Less than ~62 minutes
      Nothing -> expectationFailure "Expected message with VT"
```

## End-to-End Tests

Full Shibuya integration with pgmq adapter. These tests are tagged as "Slow" and can be skipped for faster CI runs.

**File**: `test/Shibuya/Adapter/Pgmq/E2ESpec.hs`

**Run**: `cabal test --test-option='-p' --test-option='/E2E/'`

**Skip**: Set `PGMQ_TEST_SKIP_SLOW=1` or use pattern `!/Slow/`

```haskell
describe "End-to-end with Shibuya" $ do
  it "processes messages through full Shibuya pipeline" $ withTestFixture $ \fixture -> do
    -- Enqueue messages
    runEff . runPgmq fixture.pool $ do
      forM_ [1..10 :: Int] $ \i ->
        sendMessage $ SendMessage fixture.queueName
          (Pgmq.MessageBody (object ["order_id" .= i])) Nothing

    processedRef <- newIORef []

    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName) { batchSize = 5 }
      adapter <- pgmqAdapter config

      let handler ingested = do
            liftIO $ modifyIORef' processedRef (ingested.envelope.payload :)
            pure AckOk

      result <- runApp IgnoreFailures 10
        [ (ProcessorId "orders", QueueProcessor adapter handler)
        ]

      case result of
        Left err -> liftIO $ expectationFailure $ "runApp failed: " ++ show err
        Right handle -> do
          -- Wait for processing
          liftIO $ threadDelay 1000000
          stopApp handle

    processed <- readIORef processedRef
    length processed `shouldBe` 10

  it "dead-letters poison messages via Shibuya handler" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      sendMessage $ SendMessage fixture.queueName
        (Pgmq.MessageBody (object ["type" .= ("bad" :: Text)])) Nothing
      sendMessage $ SendMessage fixture.queueName
        (Pgmq.MessageBody (object ["type" .= ("good" :: Text)])) Nothing

    runEff . runPgmq fixture.pool $ do
      let config = (defaultConfig fixture.queueName)
            { deadLetterConfig = Just DeadLetterConfig
                { dlqQueueName = fixture.dlqName,
                  includeMetadata = True
                }
            }
      adapter <- pgmqAdapter config

      let handler ingested = do
            case ingested.envelope.payload ^? key "type" . _String of
              Just "bad" -> pure $ AckDeadLetter (PoisonPill "bad type")
              _ -> pure AckOk

      result <- runApp IgnoreFailures 10
        [ (ProcessorId "processor", QueueProcessor adapter handler)
        ]

      case result of
        Left err -> liftIO $ expectationFailure $ "runApp failed: " ++ show err
        Right handle -> do
          liftIO $ threadDelay 1000000
          stopApp handle

    -- DLQ should have 1 message
    dlqCount <- runEff . runPgmq fixture.pool $ getQueueLength fixture.dlqName
    dlqCount `shouldBe` 1

  it "metrics are tracked correctly" $ withTestFixture $ \fixture -> do
    runEff . runPgmq fixture.pool $ do
      forM_ [1..5 :: Int] $ \i ->
        sendMessage $ SendMessage fixture.queueName
          (Pgmq.MessageBody (object ["n" .= i])) Nothing

    finalMetrics <- runEff . runPgmq fixture.pool $ do
      let config = defaultConfig fixture.queueName
      adapter <- pgmqAdapter config

      let handler ingested = do
            let n = ingested.envelope.payload ^? key "n" . _Integer
            case n of
              Just 3 -> pure $ AckDeadLetter (PoisonPill "three is bad")
              _ -> pure AckOk

      result <- runApp IgnoreFailures 10
        [ (ProcessorId "metrics-test", QueueProcessor adapter handler)
        ]

      case result of
        Left err -> liftIO $ expectationFailure $ "runApp failed: " ++ show err
        Right handle -> do
          liftIO $ threadDelay 1000000
          metrics <- getAllMetrics (handle.master)
          stopApp handle
          pure metrics

    case Map.lookup (ProcessorId "metrics-test") finalMetrics of
      Just m -> do
        m.stats.received `shouldBe` 5
        m.stats.processed `shouldBe` 4
        m.stats.failed `shouldBe` 1
      Nothing -> expectationFailure "Expected metrics"
```

## Performance Tests

Performance benchmarks for throughput and latency measurements. These tests are tagged as "Slow" and can be skipped for faster CI runs.

**File**: `test/Shibuya/Adapter/Pgmq/BenchmarkSpec.hs`

**Run**: `cabal test --test-option='-p' --test-option='/Benchmark/'`

**Skip**: Set `PGMQ_TEST_SKIP_SLOW=1` or use pattern `!/Slow/`

```haskell
describe "Performance benchmarks" $ do
  describe "Throughput" $ do
    it "benchmark: 1000 messages, batchSize=1" $ withTestFixture $ \fixture -> do
      runEff . runPgmq fixture.pool $ do
        forM_ [1..1000 :: Int] $ \i ->
          sendMessage $ SendMessage fixture.queueName
            (Pgmq.MessageBody (object ["n" .= i])) Nothing

      start <- getCurrentTime
      runEff . runPgmq fixture.pool $ do
        let config = (defaultConfig fixture.queueName) { batchSize = 1 }
        adapter <- pgmqAdapter config
        Stream.fold (Fold.drainMapM $ \ingested ->
          ingested.ack.finalize AckOk
        ) $ Stream.take 1000 adapter.source
      end <- getCurrentTime

      let elapsed = diffUTCTime end start
          throughput = 1000 / realToFrac elapsed :: Double

      putStrLn $ "Throughput (batch=1): " ++ show throughput ++ " msg/s"
      throughput `shouldSatisfy` (> 100)  -- At least 100 msg/s

    it "benchmark: 1000 messages, batchSize=100" $ withTestFixture $ \fixture -> do
      runEff . runPgmq fixture.pool $ do
        forM_ [1..1000 :: Int] $ \i ->
          sendMessage $ SendMessage fixture.queueName
            (Pgmq.MessageBody (object ["n" .= i])) Nothing

      start <- getCurrentTime
      runEff . runPgmq fixture.pool $ do
        let config = (defaultConfig fixture.queueName) { batchSize = 100 }
        adapter <- pgmqAdapter config
        Stream.fold (Fold.drainMapM $ \ingested ->
          ingested.ack.finalize AckOk
        ) $ Stream.take 1000 adapter.source
      end <- getCurrentTime

      let elapsed = diffUTCTime end start
          throughput = 1000 / realToFrac elapsed :: Double

      putStrLn $ "Throughput (batch=100): " ++ show throughput ++ " msg/s"
      throughput `shouldSatisfy` (> 500)  -- Should be much faster

    it "benchmark: 1000 messages, batchSize=100, prefetch=4" $ withTestFixture $ \fixture -> do
      runEff . runPgmq fixture.pool $ do
        forM_ [1..1000 :: Int] $ \i ->
          sendMessage $ SendMessage fixture.queueName
            (Pgmq.MessageBody (object ["n" .= i])) Nothing

      start <- getCurrentTime
      runEff . runPgmq fixture.pool $ do
        let config = (defaultConfig fixture.queueName)
              { batchSize = 100,
                prefetchConfig = Just PrefetchConfig { bufferSize = 4 }
              }
        adapter <- pgmqAdapter config
        Stream.fold (Fold.drainMapM $ \ingested ->
          ingested.ack.finalize AckOk
        ) $ Stream.take 1000 adapter.source
      end <- getCurrentTime

      let elapsed = diffUTCTime end start
          throughput = 1000 / realToFrac elapsed :: Double

      putStrLn $ "Throughput (batch=100, prefetch=4): " ++ show throughput ++ " msg/s"

  describe "Latency" $ do
    it "measures p50/p99 latency" $ withTestFixture $ \fixture -> do
      -- Measure individual message latencies
      latencies <- newIORef []

      runEff . runPgmq fixture.pool $ do
        forM_ [1..100 :: Int] $ \i -> do
          sendTime <- liftIO getCurrentTime
          sendMessage $ SendMessage fixture.queueName
            (Pgmq.MessageBody (object ["send_time" .= show sendTime])) Nothing

      runEff . runPgmq fixture.pool $ do
        let config = (defaultConfig fixture.queueName) { batchSize = 10 }
        adapter <- pgmqAdapter config
        Stream.fold (Fold.drainMapM $ \ingested -> do
          receiveTime <- liftIO getCurrentTime
          let sendTimeStr = ingested.envelope.payload ^? key "send_time" . _String
          case sendTimeStr >>= readMaybe . Text.unpack of
            Just sendTime -> do
              let latency = diffUTCTime receiveTime sendTime
              liftIO $ modifyIORef' latencies (latency :)
            Nothing -> pure ()
          ingested.ack.finalize AckOk
        ) $ Stream.take 100 adapter.source

      lats <- sort <$> readIORef latencies
      let p50 = lats !! 50
          p99 = lats !! 99

      putStrLn $ "Latency p50: " ++ show p50
      putStrLn $ "Latency p99: " ++ show p99
```

## Test Infrastructure

### Dependencies

Add tmp-postgres from GitHub master (not Hackage) in `cabal.project`:

```cabal
source-repository-package
  type: git
  location: https://github.com/jfischoff/tmp-postgres
  tag: 7f2467a6d6d5f6db7eed59919a6773fe006cf22b
```

The pgmq-hs libraries should also be available (either as local packages or from a source-repository-package).

Add to test-suite in `.cabal` file:

```cabal
test-suite shibuya-pgmq-adapter-test
  build-depends:
    , tmp-postgres
    , pgmq-migration          -- For installing pgmq schema
    , tasty
    , tasty-hunit
    , hasql
    , hasql-pool
```

**Note**: The `pgmq-migration` package is from [pgmq-hs](https://github.com/topagentnetwork/pgmq-hs) and provides SQL migrations to install the pgmq schema without requiring the PostgreSQL extension.

### Test Module Structure

```
test/
├── Main.hs                           -- Test runner with filtering
├── TestUtils.hs                      -- Shared test utilities
├── Shibuya/Adapter/Pgmq/
│   ├── ConvertSpec.hs                -- Unit tests (no DB)
│   ├── ConfigSpec.hs                 -- Unit tests (no DB)
│   ├── PropertySpec.hs               -- Property tests (no DB)
│   ├── InternalSpec.hs               -- Unit tests (no DB)
│   ├── IntegrationSpec.hs            -- Integration tests (DB)
│   ├── E2ESpec.hs                    -- End-to-end tests (DB, slow)
│   └── BenchmarkSpec.hs              -- Performance tests (DB, slow)
└── TmpPostgres.hs                    -- tmp-postgres setup
```

### tmp-postgres Setup

**File**: `test/TmpPostgres.hs`

```haskell
module TmpPostgres
  ( withPgmqPool,
    withPgmqPoolTree,
    TestFixture (..),
    withTestFixture,
    runSession,
  )
where

import Control.Exception (bracket)
import Data.ByteString (ByteString)
import Database.Postgres.Temp
  ( Config,
    DB,
    defaultConfig,
    startConfig,
    stop,
    toConnectionString,
  )
import Database.Postgres.Temp.Internal.Config (initDbConfig, createDbConfig)
import Hasql.Connection qualified as Connection
import Hasql.Pool qualified as Pool
import Hasql.Session (run)
import Pgmq.Migration qualified  -- From pgmq-hs for schema installation
import System.Environment (lookupEnv, setEnv, unsetEnv)
import Test.Tasty (TestTree, withResource)

-- | Configuration for tmp-postgres
-- Uses --no-sync for faster test startup
pgmqConfig :: Config
pgmqConfig =
  defaultConfig
    <> mempty
      { initDbConfig = mempty {commandLine = mempty {keyBased = [("--no-sync", Nothing)]}},
        createDbConfig = mempty {commandLine = mempty {keyBased = [("--no-sync", Nothing)]}}
      }

-- | Install pgmq schema using pgmq-migration
-- This uses the SQL migrations from pgmq-hs, not the PostgreSQL extension
installPgmq :: ByteString -> IO ()
installPgmq connStr = do
  conn <- either (error . show) id <$> Connection.acquire connStr
  result <- run Pgmq.Migration.migrate conn
  Connection.release conn
  case result of
    Right (Right ()) -> pure ()
    Right (Left migrationErr) -> error $ "Migration failed: " <> show migrationErr
    Left sessionErr -> error $ "Session failed: " <> show sessionErr

-- | Clear PostgreSQL environment variables that interfere with tmp-postgres
withCleanPgEnv :: IO a -> IO a
withCleanPgEnv action =
  bracket
    ( do
        oldPgHost <- lookupEnv "PGHOST"
        oldPgData <- lookupEnv "PGDATA"
        oldPgUser <- lookupEnv "PGUSER"
        unsetEnv "PGHOST"
        unsetEnv "PGDATA"
        unsetEnv "PGUSER"
        pure (oldPgHost, oldPgData, oldPgUser)
    )
    ( \(oldPgHost, oldPgData, oldPgUser) -> do
        maybe (pure ()) (setEnv "PGHOST") oldPgHost
        maybe (pure ()) (setEnv "PGDATA") oldPgData
        maybe (pure ()) (setEnv "PGUSER") oldPgUser
    )
    (const action)

-- | Start tmp-postgres and create a connection pool
withPgmqPool :: (Pool.Pool -> IO a) -> IO a
withPgmqPool action = withCleanPgEnv $ do
  bracket
    (either (error . show) id <$> startConfig pgmqConfig)
    stop
    $ \db -> do
      let connStr = toConnectionString db
      -- Install pgmq schema via pgmq-migration
      installPgmq connStr
      -- Create pool
      bracket
        (Pool.acquire poolSettings connStr)
        Pool.release
        action
  where
    poolSettings =
      Pool.settings
        [ Pool.size 10,
          Pool.acquisitionTimeout 10,
          Pool.agingTimeout 60,
          Pool.idlenessTimeout 60
        ]

-- | Tasty-compatible resource wrapper for tmp-postgres pool
withPgmqPoolTree :: (IO Pool.Pool -> TestTree) -> TestTree
withPgmqPoolTree = withResource startPool stopPool
  where
    startPool = withCleanPgEnv $ do
      db <- either (error . show) id <$> startConfig pgmqConfig
      let connStr = toConnectionString db
      installPgmq connStr
      pool <- Pool.acquire poolSettings connStr
      pure (db, pool)

    stopPool (db, pool) = do
      Pool.release pool
      stop db

    poolSettings =
      Pool.settings
        [ Pool.size 10,
          Pool.acquisitionTimeout 10,
          Pool.agingTimeout 60,
          Pool.idlenessTimeout 60
        ]

-- | Test fixture with queue names
data TestFixture = TestFixture
  { pool :: Pool.Pool,
    queueName :: QueueName,
    dlqName :: QueueName
  }

-- | Create a test fixture with fresh queues
-- Uses random suffixes to avoid queue name collisions
withTestFixture :: Pool.Pool -> (TestFixture -> IO a) -> IO a
withTestFixture pool action = do
  -- Generate unique queue names
  suffix <- randomSuffix
  let Right queueName = parseQueueName $ "test_" <> suffix
      Right dlqName = parseQueueName $ "test_dlq_" <> suffix

  -- Create queues
  runSession pool $ do
    createQueue queueName
    createQueue dlqName

  -- Run test
  result <- action TestFixture {pool, queueName, dlqName}

  -- Cleanup queues
  runSession pool $ do
    dropQueue queueName
    dropQueue dlqName

  pure result
  where
    randomSuffix :: IO Text
    randomSuffix = do
      uuid <- randomIO :: IO Word64
      pure $ Text.pack $ showHex uuid ""

-- | Run a session against the pool, failing on error
runSession :: Pool.Pool -> Session a -> IO a
runSession pool session =
  Pool.use pool session >>= either (error . show) pure
```

### Test Main with Filtering

**File**: `test/Main.hs`

```haskell
module Main (main) where

import System.Environment (lookupEnv)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.Ingredients.Basic (includingOptions)
import Test.Tasty.Options
import Test.Tasty.Patterns.Types (Expr)
import TmpPostgres (withPgmqPoolTree)

-- Import test modules
import Shibuya.Adapter.Pgmq.ConvertSpec qualified as ConvertSpec
import Shibuya.Adapter.Pgmq.ConfigSpec qualified as ConfigSpec
import Shibuya.Adapter.Pgmq.PropertySpec qualified as PropertySpec
import Shibuya.Adapter.Pgmq.InternalSpec qualified as InternalSpec
import Shibuya.Adapter.Pgmq.IntegrationSpec qualified as IntegrationSpec
import Shibuya.Adapter.Pgmq.E2ESpec qualified as E2ESpec
import Shibuya.Adapter.Pgmq.BenchmarkSpec qualified as BenchmarkSpec

main :: IO ()
main = do
  -- Check environment variables for test filtering
  skipSlow <- lookupEnv "PGMQ_TEST_SKIP_SLOW"
  skipDb <- lookupEnv "PGMQ_TEST_SKIP_DB"

  let unitTests = testGroup "Unit Tests"
        [ ConvertSpec.tests,
          ConfigSpec.tests,
          InternalSpec.tests
        ]

      propertyTests = testGroup "Property Tests"
        [ PropertySpec.tests
        ]

      -- Database tests are wrapped with withPgmqPoolTree
      integrationTests = withPgmqPoolTree $ \pool ->
        testGroup "Integration Tests"
          [ IntegrationSpec.tests pool
          ]

      e2eTests = withPgmqPoolTree $ \pool ->
        testGroup "Slow" -- Tag for filtering
          [ testGroup "E2E Tests"
              [ E2ESpec.tests pool
              ]
          ]

      benchmarkTests = withPgmqPoolTree $ \pool ->
        testGroup "Slow" -- Tag for filtering
          [ testGroup "Benchmark Tests"
              [ BenchmarkSpec.tests pool
              ]
          ]

      -- Build test tree based on environment
      allTests = case (skipDb, skipSlow) of
        (Just "1", _) ->
          -- Skip all database tests
          testGroup "shibuya-pgmq-adapter"
            [ unitTests,
              propertyTests
            ]
        (_, Just "1") ->
          -- Skip slow tests only
          testGroup "shibuya-pgmq-adapter"
            [ unitTests,
              propertyTests,
              integrationTests
            ]
        _ ->
          -- Run all tests
          testGroup "shibuya-pgmq-adapter"
            [ unitTests,
              propertyTests,
              integrationTests,
              e2eTests,
              benchmarkTests
            ]

  defaultMain allTests
```

### Test Helpers

**File**: `test/TestUtils.hs`

```haskell
module TestUtils
  ( -- * Database utilities
    runSession,
    tx,

    -- * Queue helpers
    getQueueLength,
    getArchiveLength,
    sendMessageWithHeaders,
    cleanupQueue,

    -- * Test conditions
    skipIfNoDb,
    skipIfSlow,
  )
where

import Control.Monad (when)
import Data.Aeson (Value (..), object, (.=))
import Hasql.Pool qualified as Pool
import Hasql.Session (Session)
import Hasql.Transaction (Transaction, statement)
import Hasql.Transaction.Sessions (transaction, IsolationLevel (..), Mode (..))
import Pgmq.Types (QueueName)
import System.Environment (lookupEnv)
import Test.Tasty.HUnit (assertFailure)

-- | Run a session, failing test on error
runSession :: Pool.Pool -> Session a -> IO a
runSession pool session =
  Pool.use pool session >>= either (assertFailure . show) pure

-- | Run a transaction with Serializable isolation
tx :: Transaction a -> Session a
tx = transaction Serializable Write

-- | Get the number of messages in a queue
getQueueLength :: Pool.Pool -> QueueName -> IO Int
getQueueLength pool queueName =
  runSession pool $ do
    -- Use pgmq.metrics or direct query
    result <- statement () [Statement.stmt|
      SELECT count(*)::int FROM pgmq.q_$1
      |]
    pure result

-- | Get the number of archived messages
getArchiveLength :: Pool.Pool -> QueueName -> IO Int
getArchiveLength pool queueName =
  runSession pool $ do
    result <- statement () [Statement.stmt|
      SELECT count(*)::int FROM pgmq.a_$1
      |]
    pure result

-- | Send a message with custom headers (for FIFO testing)
sendMessageWithHeaders ::
  Pool.Pool ->
  QueueName ->
  Value ->   -- body
  Value ->   -- headers
  IO ()
sendMessageWithHeaders pool queueName body headers =
  runSession pool $ do
    statement (queueName, body, headers) [Statement.stmt|
      SELECT pgmq.send($1, $2::jsonb, $3::jsonb)
      |]

-- | Clean up all messages from a queue
cleanupQueue :: Pool.Pool -> QueueName -> IO ()
cleanupQueue pool queueName =
  runSession pool $ do
    statement queueName [Statement.stmt|
      DELETE FROM pgmq.q_$1
      |]

-- | Skip test if PGMQ_TEST_SKIP_DB is set
skipIfNoDb :: IO () -> IO ()
skipIfNoDb action = do
  skipDb <- lookupEnv "PGMQ_TEST_SKIP_DB"
  when (skipDb /= Just "1") action

-- | Skip test if PGMQ_TEST_SKIP_SLOW is set
skipIfSlow :: IO () -> IO ()
skipIfSlow action = do
  skipSlow <- lookupEnv "PGMQ_TEST_SKIP_SLOW"
  when (skipSlow /= Just "1") action
```

### Integration Test Structure

**File**: `test/Shibuya/Adapter/Pgmq/IntegrationSpec.hs`

```haskell
module Shibuya.Adapter.Pgmq.IntegrationSpec (tests) where

import Hasql.Pool qualified as Pool
import Test.Tasty
import Test.Tasty.HUnit
import TmpPostgres (TestFixture (..), withTestFixture)
import TestUtils (runSession)

tests :: IO Pool.Pool -> TestTree
tests getPool = testGroup "Integration"
  [ testCase "processes a single message" $ do
      pool <- getPool
      withTestFixture pool $ \fixture -> do
        -- Test implementation
        pure (),

    testCase "visibility timeout prevents double processing" $ do
      pool <- getPool
      withTestFixture pool $ \fixture -> do
        -- Test implementation
        pure ()

    -- ... more tests
  ]
```

### E2E Test Structure with Slow Tag

**File**: `test/Shibuya/Adapter/Pgmq/E2ESpec.hs`

```haskell
module Shibuya.Adapter.Pgmq.E2ESpec (tests) where

import Hasql.Pool qualified as Pool
import Test.Tasty
import Test.Tasty.HUnit
import TmpPostgres (TestFixture (..), withTestFixture)

-- | E2E tests - these are slow and require full Shibuya setup
-- Run with: cabal test --test-option='-p' --test-option='/E2E/'
-- Skip with: cabal test --test-option='-p' --test-option='!/Slow/'
tests :: IO Pool.Pool -> TestTree
tests getPool = testGroup "E2E"
  [ testCase "processes messages through full Shibuya pipeline" $ do
      pool <- getPool
      withTestFixture pool $ \fixture -> do
        -- Full pipeline test
        pure (),

    testCase "dead-letters poison messages via Shibuya handler" $ do
      pool <- getPool
      withTestFixture pool $ \fixture -> do
        -- DLQ test
        pure ()
  ]
```

### Benchmark Structure with Slow Tag

**File**: `test/Shibuya/Adapter/Pgmq/BenchmarkSpec.hs`

```haskell
module Shibuya.Adapter.Pgmq.BenchmarkSpec (tests) where

import Hasql.Pool qualified as Pool
import Test.Tasty
import Test.Tasty.HUnit
import TmpPostgres (TestFixture (..), withTestFixture)

-- | Benchmark tests - these are slow
-- Run with: cabal test --test-option='-p' --test-option='/Benchmark/'
-- Skip with: cabal test --test-option='-p' --test-option='!/Slow/'
tests :: IO Pool.Pool -> TestTree
tests getPool = testGroup "Benchmark"
  [ testCase "throughput: 1000 messages, batchSize=1" $ do
      pool <- getPool
      withTestFixture pool $ \fixture -> do
        -- Throughput test
        pure (),

    testCase "throughput: 1000 messages, batchSize=100" $ do
      pool <- getPool
      withTestFixture pool $ \fixture -> do
        -- Throughput test with batching
        pure ()
  ]
```

## Test Matrix

### Configuration Combinations

| Test | Standard Poll | Long Poll | FIFO-TO | FIFO-RR | Prefetch | DLQ |
|------|:-------------:|:---------:|:-------:|:-------:|:--------:|:---:|
| Basic processing | ✓ | ✓ | ✓ | ✓ | ✓ | - |
| Visibility timeout | ✓ | ✓ | - | - | - | - |
| Auto dead-letter | ✓ | - | - | - | - | ✓ |
| Manual dead-letter | ✓ | - | - | - | - | ✓ |
| Archive (no DLQ) | ✓ | - | - | - | - | - |
| Lease extension | ✓ | - | - | - | - | - |
| Batch flattening | ✓ | ✓ | ✓ | ✓ | ✓ | - |
| Group ordering | - | - | ✓ | ✓ | - | - |
| Shutdown | ✓ | ✓ | - | - | ✓ | - |
| AckHalt | ✓ | - | - | - | - | - |
| Throughput | ✓ | - | - | - | ✓ | - |

### Edge Cases

| Scenario | Expected Behavior |
|----------|-------------------|
| Empty queue with standard poll | Sleeps for pollInterval |
| Empty queue with long poll | Blocks up to maxPollSeconds |
| readCount exactly at maxRetries | Message is processed normally |
| readCount one above maxRetries | Message is auto-DLQ'd |
| Lease extend on deleted message | Error logged, no crash |
| Shutdown during long poll | Unblocks on next poll cycle |
| Zero batchSize | Uses default (1) |
| Negative visibilityTimeout | Validation error |
| Missing x-pgmq-group header | partition = Nothing |
| Non-string x-pgmq-group | partition = Nothing |

### Concurrency Scenarios

| Scenario | Test Approach |
|----------|---------------|
| Multiple consumers same queue | Spawn multiple adapters, verify no duplicates |
| Prefetch with slow handler | Ensure VT not exceeded |
| Rapid shutdown/restart | No message loss |
| Handler timeout | Message reappears after VT |
