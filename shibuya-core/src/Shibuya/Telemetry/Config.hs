-- | Tracing configuration for Shibuya.
-- Most configuration is handled via OTEL_* environment variables
-- by the hs-opentelemetry SDK. This module provides the minimal
-- application-level config.
module Shibuya.Telemetry.Config
  ( TracingConfig (..),
    defaultTracingConfig,
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

-- | Tracing configuration.
-- The SDK reads most settings from OTEL_* environment variables.
data TracingConfig = TracingConfig
  { -- | Master switch for tracing. When False, runTracingNoop is used.
    enabled :: !Bool,
    -- | Service name (fallback if OTEL_SERVICE_NAME not set)
    serviceName :: !Text,
    -- | Service version for span attributes
    serviceVersion :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Default tracing config with tracing disabled.
defaultTracingConfig :: TracingConfig
defaultTracingConfig =
  TracingConfig
    { enabled = False,
      serviceName = "shibuya",
      serviceVersion = Nothing
    }
