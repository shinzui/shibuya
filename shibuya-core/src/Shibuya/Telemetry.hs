-- | OpenTelemetry tracing support for Shibuya.
--
-- This module re-exports all telemetry-related types and functions.
--
-- == Quick Start
--
-- 1. Enable tracing in your config:
--
-- @
-- config = defaultAppConfig
--   { tracing = defaultTracingConfig { enabled = True }
--   }
-- @
--
-- 2. Set environment variables for the OTLP exporter:
--
-- @
-- export OTEL_SERVICE_NAME="my-service"
-- export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
-- @
--
-- 3. Spans are automatically created for message processing.
--    See "Shibuya.Telemetry.Effect" for custom instrumentation.
module Shibuya.Telemetry
  ( -- * Configuration
    module Shibuya.Telemetry.Config,

    -- * Effect
    module Shibuya.Telemetry.Effect,

    -- * Context Propagation
    module Shibuya.Telemetry.Propagation,

    -- * Semantic Conventions
    module Shibuya.Telemetry.Semantic,
  )
where

import Shibuya.Telemetry.Config
import Shibuya.Telemetry.Effect
import Shibuya.Telemetry.Propagation
import Shibuya.Telemetry.Semantic
