{-# LANGUAGE OverloadedStrings #-}

-- | Asserts that spans emitted by 'processOne' carry the wire names
-- defined by the OpenTelemetry messaging semantic conventions and the
-- shibuya-namespaced fallbacks. This is the guard that catches drift
-- between Shibuya's emitted attributes and the upstream spec — a future
-- rename in @hs-opentelemetry-semantic-conventions@ will break both
-- compilation (because @Shibuya.Telemetry.Semantic@ derives the strings
-- from typed @AttributeKey@s) and these assertions (because the wire
-- string changed).
module Shibuya.Telemetry.SemanticSpec (spec) where

import Data.Foldable (toList)
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (readIORef)
import Data.Int (Int64)
import Data.Text (Text)
import Effectful (runEff)
import OpenTelemetry.Attributes
  ( Attribute (..),
    PrimitiveAttribute (..),
    emptyAttributes,
    getAttributeMap,
    toAttribute,
  )
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Trace.Core
  ( Event (..),
    ImmutableSpan (..),
    InstrumentationLibrary (..),
    SpanStatus (..),
    createTracerProvider,
    emptyTracerProviderOptions,
    hotAttributes,
    hotEvents,
    hotName,
    hotStatus,
    makeTracer,
    shutdownTracerProvider,
    tracerOptions,
  )
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Shibuya.Adapter.Mock (listAdapter)
import Shibuya.Core.Ack
  ( AckDecision (..),
    DeadLetterCode,
    DeadLetterReason (..),
    mkDeadLetterCode,
  )
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Internal.Runner.Supervised (runWithMetrics)
import Shibuya.Telemetry.Effect (runTracing)
import Shibuya.Telemetry.Semantic (attrShibuyaDeadLetterReasonCode)
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.Telemetry.Semantic (wire-format)" $ do
  it "keeps the application dead-letter reason code wire key stable" $ do
    attrShibuyaDeadLetterReasonCode
      `shouldBe` "shibuya.dead_letter.reason.code"

  it "emits a process span with conventions-aligned attributes and events" $ do
    (processor, spansRef) <- inMemoryListExporter
    provider <- createTracerProvider [processor] emptyTracerProviderOptions
    let tracer = mkTestTracer provider

    runEff $ runTracing tracer $ do
      let envelope =
            mkEnvelope (MessageId "m-1") ("hello" :: Text)
          ingested = mkIngested envelope (AckHandle (\_ -> pure ()))
          adapter = listAdapter [ingested]
          handler _ = pure AckOk
          procId = ProcessorId "test-proc"
      _ <- runWithMetrics 4 procId adapter handler
      pure ()

    _ <- shutdownTracerProvider provider (Just 5_000_000)
    spans <- readIORef spansRef
    case spans of
      [s] -> do
        hot <- readIORef (spanHot s)
        hotName hot `shouldBe` "test-proc process"
        let attrs = getAttributeMap (hotAttributes hot)
        attrs `shouldHaveTextAttribute` ("messaging.system", "shibuya")
        attrs `shouldHaveTextAttribute` ("messaging.message.id", "m-1")
        attrs `shouldHaveTextAttribute` ("messaging.destination.name", "test-proc")
        attrs `shouldHaveTextAttribute` ("messaging.operation.type", "process")
        attrs `shouldHaveTextAttribute` ("shibuya.ack.decision", "ack_ok")
        attrs `shouldHaveIntAttribute` ("shibuya.inflight.count", 1)
        attrs `shouldHaveIntAttribute` ("shibuya.inflight.max", 1)
        let evNames = map eventName (toList (appendOnlyBoundedCollectionValues (hotEvents hot)))
        evNames `shouldContain` ["shibuya.handler.started"]
        evNames `shouldContain` ["shibuya.handler.completed"]
      _ ->
        expectationFailure $ "expected exactly one span, got " <> show (length spans)

  it "applies envelope.attributes onto the framework span (P0 fix, plan 9 F1/F2)" $ do
    -- The adapter contributes broker-specific typed attributes via
    -- 'Envelope.attributes'. The framework's processOne span must carry
    -- them, and adapter-supplied keys must override framework defaults
    -- of the same name (here: messaging.system flips from "shibuya" to
    -- "kafka" because the adapter set it).
    (processor, spansRef) <- inMemoryListExporter
    provider <- createTracerProvider [processor] emptyTracerProviderOptions
    let tracer = mkTestTracer provider

    runEff $ runTracing tracer $ do
      let envelope =
            (mkEnvelope (MessageId "orders-2-42") ("hello" :: Text))
              { attributes =
                  HashMap.fromList
                    [ ("messaging.system", toAttribute ("kafka" :: Text)),
                      ( "messaging.kafka.destination.partition",
                        toAttribute (2 :: Int64)
                      ),
                      ( "messaging.kafka.message.offset",
                        toAttribute (42 :: Int64)
                      )
                    ]
              }
          ingested = mkIngested envelope (AckHandle (\_ -> pure ()))
          adapter = listAdapter [ingested]
          handler _ = pure AckOk
          procId = ProcessorId "orders-consumer"
      _ <- runWithMetrics 4 procId adapter handler
      pure ()

    _ <- shutdownTracerProvider provider (Just 5_000_000)
    spans <- readIORef spansRef
    case spans of
      [s] -> do
        hot <- readIORef (spanHot s)
        let attrs = getAttributeMap (hotAttributes hot)
        -- Adapter override wins.
        attrs `shouldHaveTextAttribute` ("messaging.system", "kafka")
        -- Adapter-typed attributes appear on the framework span.
        attrs `shouldHaveIntAttribute` ("messaging.kafka.destination.partition", 2)
        attrs `shouldHaveIntAttribute` ("messaging.kafka.message.offset", 42)
        -- Framework defaults still set where the adapter did not override.
        attrs `shouldHaveTextAttribute` ("messaging.destination.name", "orders-consumer")
        attrs `shouldHaveTextAttribute` ("messaging.operation.type", "process")
        attrs `shouldHaveTextAttribute` ("messaging.message.id", "orders-2-42")
      _ ->
        expectationFailure $
          "expected exactly one span, got " <> show (length spans)

  it "emits an application dead-letter code and canonical error status" $ do
    (processor, spansRef) <- inMemoryListExporter
    provider <- createTracerProvider [processor] emptyTracerProviderOptions
    let tracer = mkTestTracer provider
        code = validDeadLetterCode "keiro.router.selection.recipient_overflow"
        detail = "selected 101 recipients; configured limit is 100"

    runEff $ runTracing tracer $ do
      let envelope = mkEnvelope (MessageId "router-1") ("hello" :: Text)
          ingested = mkIngested envelope (AckHandle (\_ -> pure ()))
          adapter = listAdapter [ingested]
          handler _ = pure $ AckDeadLetter $ ApplicationFailure code detail
          procId = ProcessorId "router-consumer"
      _ <- runWithMetrics 1 procId adapter handler
      pure ()

    _ <- shutdownTracerProvider provider (Just 5_000_000)
    spans <- readIORef spansRef
    case spans of
      [s] -> do
        hot <- readIORef (spanHot s)
        let attrs = getAttributeMap (hotAttributes hot)
        attrs `shouldHaveTextAttribute` ("shibuya.ack.decision", "ack_dead_letter")
        attrs
          `shouldHaveTextAttribute` ( "shibuya.dead_letter.reason.code",
                                      "keiro.router.selection.recipient_overflow"
                                    )
        hotStatus hot
          `shouldBe` Error "keiro.router.selection.recipient_overflow: selected 101 recipients; configured limit is 100"
      _ ->
        expectationFailure $
          "expected exactly one span, got " <> show (length spans)
  where
    mkTestTracer p =
      makeTracer
        p
        ( InstrumentationLibrary
            { libraryName = "shibuya-test",
              libraryVersion = "",
              librarySchemaUrl = "",
              libraryAttributes = emptyAttributes
            }
        )
        tracerOptions
    shouldHaveTextAttribute :: HashMap Text Attribute -> (Text, Text) -> Expectation
    shouldHaveTextAttribute attrs (k, expected) =
      case HashMap.lookup k attrs of
        Just (AttributeValue (TextAttribute v)) -> v `shouldBe` expected
        Just other ->
          expectationFailure $
            "attribute " <> show k <> " was not a Text: " <> show other
        Nothing ->
          expectationFailure $
            "attribute " <> show k <> " missing; have keys " <> show (HashMap.keys attrs)
    shouldHaveIntAttribute :: HashMap Text Attribute -> (Text, Int) -> Expectation
    shouldHaveIntAttribute attrs (k, expected) =
      case HashMap.lookup k attrs of
        Just (AttributeValue (IntAttribute v)) -> v `shouldBe` fromIntegral expected
        Just other ->
          expectationFailure $
            "attribute " <> show k <> " was not an Int: " <> show other
        Nothing ->
          expectationFailure $
            "attribute " <> show k <> " missing; have keys " <> show (HashMap.keys attrs)

validDeadLetterCode :: Text -> DeadLetterCode
validDeadLetterCode code =
  case mkDeadLetterCode code of
    Left err -> error $ "invalid test fixture: " <> show err
    Right valid -> valid
