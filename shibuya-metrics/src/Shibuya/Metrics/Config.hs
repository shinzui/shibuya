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
  { -- | Port to listen on (default: 9090)
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
    -- | Timeout for liveness check in microseconds (default: 1_000_000 = 1s)
    livenessTimeoutMicros :: !Int,
    -- | How long a processor can be in Processing state before considered stuck (default: 60s)
    stuckThreshold :: !NominalDiffTime
  }
  deriving stock (Eq, Show, Generic)

-- | Default configuration.
defaultConfig :: MetricsServerConfig
defaultConfig =
  MetricsServerConfig
    { port = 9090,
      enableJSON = True,
      enablePrometheus = True,
      enableWebSocket = True,
      wsPushIntervalUs = 100_000, -- 100ms
      wsMaxConnections = 100,
      livenessTimeoutMicros = 1_000_000, -- 1 second
      stuckThreshold = 60 -- 60 seconds
    }
