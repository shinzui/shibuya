-- | OpenTelemetry setup for the PGMQ example.
--
-- Note: Due to proto-lens compatibility issues with GHC 9.12, the full SDK
-- with OTLP export is not available. This module provides a basic tracer
-- setup. For production use with GHC 9.10 or earlier, you can use the full
-- hs-opentelemetry-sdk.
--
-- When tracing is enabled, spans will be created but not exported unless
-- you configure an exporter manually.
module Example.Telemetry
  ( -- * Tracer Provider Setup
    withTracing,

    -- * Re-exports
    OTel.Tracer,
  )
where

import Data.Text (Text)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Trace.Core qualified as OTel

-- | Run an action with tracing configured.
--
-- When tracing is enabled, creates a TracerProvider. Note that due to
-- GHC 9.12 compatibility, OTLP export is not automatically configured.
-- For production use, consider using GHC 9.10 with the full SDK.
--
-- When disabled, creates a no-op tracer with zero overhead.
withTracing :: Bool -> Text -> (OTel.Tracer -> IO a) -> IO a
withTracing enabled serviceName action
  | enabled = withRealTracing serviceName action
  | otherwise = withNoopTracing action

-- | Create a tracer provider and run action.
--
-- Note: This creates a basic tracer without OTLP export due to proto-lens
-- compatibility issues with GHC 9.12. The tracing effect will still work
-- for creating spans and adding context, but spans won't be exported
-- unless you manually configure an exporter.
withRealTracing :: Text -> (OTel.Tracer -> IO a) -> IO a
withRealTracing serviceName action = do
  -- Create a basic tracer provider
  -- For GHC 9.10 with full SDK, use initializeGlobalTracerProvider
  provider <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
  let tracer = OTel.makeTracer provider instrumentationLib OTel.tracerOptions
  result <- action tracer
  OTel.shutdownTracerProvider provider
  pure result
  where
    instrumentationLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = serviceName,
          OTel.libraryVersion = "0.1.0.0",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }

-- | Create a no-op tracer and run action.
withNoopTracing :: (OTel.Tracer -> IO a) -> IO a
withNoopTracing action = do
  provider <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
  let tracer = OTel.makeTracer provider noopLib OTel.tracerOptions
  action tracer
  where
    noopLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = "noop",
          OTel.libraryVersion = "",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }
