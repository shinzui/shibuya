-- | OpenTelemetry tracing support for Shibuya.
--
-- This module re-exports all telemetry-related types and functions.
--
-- == Quick Start
--
-- 1. Initialize a tracer and run your app under 'runTracing'
--    (or 'runTracingNoop' to disable tracing):
--
-- @
-- provider <- OTel.initializeTracerProvider
-- let tracer = OTel.makeTracer provider instrumentationLibrary OTel.tracerOptions
-- runEff $ runTracing tracer app
-- @
--
-- 2. Configure the OTLP exporter with environment variables:
--
-- @
-- export OTEL_SERVICE_NAME="my-service"
-- export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
-- @
--
-- 3. Spans are created automatically per message; see
--    "Shibuya.Telemetry.Effect" for custom instrumentation.
module Shibuya.Telemetry
  ( -- * Effect
    module Shibuya.Telemetry.Effect,

    -- * Context Propagation
    module Shibuya.Telemetry.Propagation,

    -- * Semantic Conventions
    module Shibuya.Telemetry.Semantic,
  )
where

import Shibuya.Telemetry.Effect
import Shibuya.Telemetry.Propagation
import Shibuya.Telemetry.Semantic
