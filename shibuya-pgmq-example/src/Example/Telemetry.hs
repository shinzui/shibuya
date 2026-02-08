-- | OpenTelemetry setup for the PGMQ example.
--
-- Uses the hs-opentelemetry-sdk with OTLP exporter. Configuration is
-- done via environment variables:
--
-- - OTEL_SERVICE_NAME: Service name (defaults to "shibuya-pgmq-example")
-- - OTEL_EXPORTER_OTLP_ENDPOINT: OTLP endpoint (defaults to http://localhost:4317)
-- - OTEL_TRACES_EXPORTER: Exporter type (defaults to "otlp")
-- - OTEL_SDK_DISABLED: Set to "true" to disable SDK
--
-- For Jaeger, start it with OTLP support:
--   jaeger --collector.otlp.enabled=true
--
-- Then traces will be visible at http://localhost:16686
module Example.Telemetry
  ( -- * Tracer Provider Setup
    withTracing,

    -- * Re-exports
    OTel.Tracer,
  )
where

import Control.Exception (bracket)
import Data.Text (Text)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Trace qualified as OTel

-- | Run an action with tracing configured.
--
-- When tracing is enabled, initializes the global TracerProvider with
-- OTLP exporter (configured via environment variables). When disabled,
-- creates a no-op tracer with zero overhead.
withTracing :: Bool -> Text -> (OTel.Tracer -> IO a) -> IO a
withTracing enabled serviceName action
  | enabled = withRealTracing serviceName action
  | otherwise = withNoopTracing serviceName action

-- | Initialize the global tracer provider and run action.
--
-- Uses environment variables for configuration:
-- - OTEL_EXPORTER_OTLP_ENDPOINT (default: http://localhost:4317)
-- - OTEL_SERVICE_NAME (overridden by serviceName parameter if not set)
-- - OTEL_TRACES_EXPORTER (default: otlp)
withRealTracing :: Text -> (OTel.Tracer -> IO a) -> IO a
withRealTracing serviceName action =
  bracket
    OTel.initializeGlobalTracerProvider
    OTel.shutdownTracerProvider
    $ \provider -> do
      let tracer = OTel.makeTracer provider instrumentationLib OTel.tracerOptions
      action tracer
  where
    instrumentationLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = serviceName,
          OTel.libraryVersion = "0.1.0.0",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }

-- | Create a no-op tracer and run action.
withNoopTracing :: Text -> (OTel.Tracer -> IO a) -> IO a
withNoopTracing _serviceName action = do
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
