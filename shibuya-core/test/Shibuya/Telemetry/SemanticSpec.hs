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
import Data.Text (Text)
import Effectful (runEff)
import OpenTelemetry.Attributes
  ( Attribute (..),
    PrimitiveAttribute (..),
    emptyAttributes,
    getAttributeMap,
  )
import OpenTelemetry.Exporter.InMemory.Span (inMemoryListExporter)
import OpenTelemetry.Trace.Core
  ( Event (..),
    ImmutableSpan (..),
    InstrumentationLibrary (..),
    createTracerProvider,
    emptyTracerProviderOptions,
    makeTracer,
    shutdownTracerProvider,
    tracerOptions,
  )
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Shibuya.Adapter.Mock (listAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Runner.Supervised (runWithMetrics)
import Shibuya.Telemetry.Effect (runTracing)
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.Telemetry.Semantic (wire-format)" $ do
  it "emits a process span with conventions-aligned attributes and events" $ do
    (processor, spansRef) <- inMemoryListExporter
    provider <- createTracerProvider [processor] emptyTracerProviderOptions
    let tracer =
          makeTracer
            provider
            ( InstrumentationLibrary
                { libraryName = "shibuya-test",
                  libraryVersion = "",
                  librarySchemaUrl = "",
                  libraryAttributes = emptyAttributes
                }
            )
            tracerOptions

    runEff $ runTracing tracer $ do
      let envelope =
            Envelope
              { messageId = MessageId "m-1",
                cursor = Nothing,
                partition = Nothing,
                enqueuedAt = Nothing,
                traceContext = Nothing,
                payload = ("hello" :: Text)
              }
          ingested =
            Ingested
              { envelope = envelope,
                ack = AckHandle (\_ -> pure ()),
                lease = Nothing
              }
          adapter = listAdapter [ingested]
          handler _ = pure AckOk
          procId = ProcessorId "test-proc"
      _ <- runWithMetrics 4 procId adapter handler
      pure ()

    _ <- shutdownTracerProvider provider
    spans <- readIORef spansRef
    case spans of
      [s] -> do
        spanName s `shouldBe` "test-proc process"
        let attrs = getAttributeMap (spanAttributes s)
        attrs `shouldHaveTextAttribute` ("messaging.system", "shibuya")
        attrs `shouldHaveTextAttribute` ("messaging.message.id", "m-1")
        attrs `shouldHaveTextAttribute` ("messaging.destination.name", "test-proc")
        attrs `shouldHaveTextAttribute` ("messaging.operation", "process")
        attrs `shouldHaveTextAttribute` ("shibuya.ack.decision", "ack_ok")
        attrs `shouldHaveIntAttribute` ("shibuya.inflight.count", 1)
        attrs `shouldHaveIntAttribute` ("shibuya.inflight.max", 1)
        let evNames = map eventName (toList (appendOnlyBoundedCollectionValues (spanEvents s)))
        evNames `shouldContain` ["shibuya.handler.started"]
        evNames `shouldContain` ["shibuya.handler.completed"]
      _ ->
        expectationFailure $ "expected exactly one span, got " <> show (length spans)
  where
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
