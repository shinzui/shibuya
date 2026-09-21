-- | Configuration for the metrics web server.
module Shibuya.Metrics.Config
  ( MetricsServerConfig (..),
    defaultConfig,
  )
where

import Data.Time.Clock (NominalDiffTime)
import GHC.Generics (Generic)

-- | Configuration for the metrics web server.
data MetricsServerConfig = MetricsServerConfig
  { -- | Host to listen on (default: loopback only, @127.0.0.1@).
    --
    -- Set this to @*@ only behind an authentication and authorization boundary;
    -- metrics and terminal failure details are operationally sensitive.
    host :: !String,
    -- | Port to listen on (default: 9090)
    port :: !Int,
    -- | Enable JSON endpoints (default: True)
    enableJSON :: !Bool,
    -- | Enable Prometheus endpoint (default: True)
    enablePrometheus :: !Bool,
    -- | Enable WebSocket endpoint (default: True)
    enableWebSocket :: !Bool,
    -- | WebSocket push interval in microseconds (default: 100_000 = 100ms)
    wsPushIntervalUs :: !Int,
    -- | Maximum WebSocket connections (default: 100)
    wsMaxConnections :: !Int,
    -- | Maximum retained processor identifiers per WebSocket connection
    -- (default: 1,000). A client exceeding this policy is disconnected.
    wsMaxSubscriptions :: !Int,
    -- | Timeout for liveness check in microseconds (default: 1_000_000 = 1s)
    livenessTimeoutMicros :: !Int,
    -- | Timeout for each dependency readiness check in microseconds (default: 1s)
    dependencyTimeoutMicros :: !Int,
    -- | How long a processor can be in Processing state before considered stuck (default: 60s)
    stuckThreshold :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

-- | Default configuration.
defaultConfig :: MetricsServerConfig
defaultConfig =
  MetricsServerConfig
    { host = "127.0.0.1",
      port = 9090,
      enableJSON = True,
      enablePrometheus = True,
      enableWebSocket = True,
      wsPushIntervalUs = 100_000, -- 100ms
      wsMaxConnections = 100,
      wsMaxSubscriptions = 1_000,
      livenessTimeoutMicros = 1_000_000, -- 1 second
      dependencyTimeoutMicros = 1_000_000, -- 1 second per dependency
      stuckThreshold = 60 -- 60 seconds
    }
