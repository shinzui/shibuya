{-# LANGUAGE OverloadedStrings #-}

-- | Tests for W3C Trace Context propagation.
module Shibuya.Telemetry.PropagationSpec (spec) where

import Data.ByteString (ByteString)
import Effectful (runEff)
import OpenTelemetry.Attributes (emptyAttributes)
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Trace.Core
  ( InstrumentationLibrary (..),
    createTracerProvider,
    defaultSpanArguments,
    emptyTracerProviderOptions,
    makeTracer,
    shutdownTracerProvider,
    tracerOptions,
  )
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Trace.Id (Base (..))
import OpenTelemetry.Trace.Id qualified as OTel.Id
import Shibuya.Telemetry.Effect (runTracing, runTracingNoop, withSpan)
import Shibuya.Telemetry.Propagation (currentTraceHeaders, extractTraceContext)
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.Telemetry.Propagation" $ do
  describe "extractTraceContext" $ do
    it "extracts valid W3C traceparent header" $ do
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
            ]
      case extractTraceContext headers of
        Nothing -> expectationFailure "Expected to extract trace context"
        Just ctx -> do
          -- Verify trace ID
          OTel.Id.traceIdBaseEncodedText Base16 (OTel.traceId ctx) `shouldBe` "0af7651916cd43dd8448eb211c80319c"
          -- Verify span ID
          OTel.Id.spanIdBaseEncodedText Base16 (OTel.spanId ctx) `shouldBe` "b7ad6b7169203331"

    it "extracts traceparent with tracestate" $ do
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"),
              ("tracestate", "congo=t61rcWkgMzE,rojo=00f067aa0ba902b7")
            ]
      case extractTraceContext headers of
        Nothing -> expectationFailure "Expected to extract trace context"
        Just ctx -> do
          OTel.Id.traceIdBaseEncodedText Base16 (OTel.traceId ctx) `shouldBe` "0af7651916cd43dd8448eb211c80319c"
          OTel.Id.spanIdBaseEncodedText Base16 (OTel.spanId ctx) `shouldBe` "b7ad6b7169203331"

    it "returns Nothing for missing traceparent" $ do
      let headers :: [(ByteString, ByteString)]
          headers = []
      extractTraceContext headers `shouldBe` Nothing

    it "returns Nothing for invalid traceparent format" $ do
      let headers :: [(ByteString, ByteString)]
          headers = [("traceparent", "invalid-format")]
      extractTraceContext headers `shouldBe` Nothing

    it "rejects traceparent with non-standard version" $ do
      -- hs-opentelemetry 1.0 validates the traceparent version strictly.
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("traceparent", "ff-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
            ]
      extractTraceContext headers `shouldBe` Nothing

    it "rejects traceparent with all-zero trace ID" $ do
      -- hs-opentelemetry 1.0 rejects all-zero trace IDs.
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("traceparent", "00-00000000000000000000000000000000-b7ad6b7169203331-01")
            ]
      extractTraceContext headers `shouldBe` Nothing

    it "rejects traceparent with all-zero span ID" $ do
      -- hs-opentelemetry 1.0 rejects all-zero span IDs.
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-0000000000000000-01")
            ]
      extractTraceContext headers `shouldBe` Nothing

    it "handles unsampled trace flag (00)" $ do
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-00")
            ]
      case extractTraceContext headers of
        Nothing -> expectationFailure "Expected to extract trace context"
        Just _ctx -> pure () -- Just verify it parses
    it "handles sampled trace flag (01)" $ do
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
            ]
      case extractTraceContext headers of
        Nothing -> expectationFailure "Expected to extract trace context"
        Just _ctx -> pure () -- Just verify it parses
    it "ignores case-sensitivity of header names" $ do
      -- W3C spec says header names are case-insensitive
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("Traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
            ]
      -- Note: This depends on how lookup handles case.
      -- The current implementation uses exact match, so this should return Nothing
      -- This is a known limitation - header normalization should happen at the adapter level
      extractTraceContext headers `shouldBe` Nothing

    it "extracts only traceparent when tracestate is malformed" $ do
      let headers :: [(ByteString, ByteString)]
          headers =
            [ ("traceparent", "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"),
              ("tracestate", "malformed tracestate value!!!")
            ]
      -- Should still extract the traceparent even if tracestate is invalid
      case extractTraceContext headers of
        Nothing -> expectationFailure "Expected to extract trace context despite malformed tracestate"
        Just ctx -> do
          OTel.Id.traceIdBaseEncodedText Base16 (OTel.traceId ctx) `shouldBe` "0af7651916cd43dd8448eb211c80319c"

  describe "currentTraceHeaders" $ do
    it "returns Nothing when tracing is disabled" $ do
      result <- runEff $ runTracingNoop currentTraceHeaders
      result `shouldBe` Nothing

    it "returns Nothing outside any active span" $ do
      provider <- createTracerProvider [] emptyTracerProviderOptions
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
      result <- runEff $ runTracing tracer currentTraceHeaders
      _ <- shutdownTracerProvider provider (Just 5_000_000)
      result `shouldBe` Nothing

    it "returns headers carrying the active span's traceparent" $ do
      (processor, _spansRef) <- inMemoryListExporter
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
      result <- runEff $ runTracing tracer $ withSpan "outer" defaultSpanArguments currentTraceHeaders
      _ <- shutdownTracerProvider provider (Just 5_000_000)
      case result of
        Nothing -> expectationFailure "expected currentTraceHeaders to return Just"
        Just hs -> case lookup "traceparent" hs of
          Nothing -> expectationFailure "expected traceparent header to be present"
          Just _ -> pure ()
