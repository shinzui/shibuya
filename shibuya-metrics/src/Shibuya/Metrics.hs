-- | Metrics web server for Shibuya queue processing framework.
--
-- This module provides HTTP/JSON, Prometheus, and WebSocket endpoints
-- for exposing Shibuya processor metrics.
--
-- == Quick Start
--
-- @
-- import Shibuya.App (runApp, AppHandle, getAppMaster)
-- import Shibuya.Metrics
--
-- main :: IO ()
-- main = do
--   -- Start your Shibuya app...
--   Right appHandle <- runEff $ runApp ...
--
--   -- Start metrics server on port 9090
--   withMetricsServer defaultConfig (getAppMaster appHandle) $ \\server -> do
--     putStrLn $ "Metrics server running on port " ++ show server.serverPort
--     -- Your app logic here...
-- @
--
-- == Endpoints
--
-- * @GET /metrics@ - JSON metrics for all processors
-- * @GET /metrics/:id@ - JSON metrics for a specific processor
-- * @GET /health@ - Detailed health status (for debugging)
-- * @GET /health/live@ - Liveness probe (Kubernetes)
-- * @GET /health/ready@ - Readiness probe (Kubernetes)
-- * @GET /metrics/prometheus@ - Prometheus-format metrics
-- * @WS /ws@ - WebSocket for real-time updates
--
-- == Cross-origin access
--
-- Set 'corsAllowedOrigins' to explicit serialized browser origins, for example
-- @defaultConfig {corsAllowedOrigins = ["https://ops.example.com"]}@. The empty
-- default preserves read-route headers and WebSocket upgrade behavior. Wildcards,
-- whitespace, paths, queries and fragments are refused by the built-in server.
-- Matching is exact, without case folding or default-port normalization.
-- Allowed HTTP responses (including errors) gain @Access-Control-Allow-Origin@;
-- enabled responses merge @Vary: Origin@ even for absent or refused origins.
-- Preflight @OPTIONS@ requests allow @GET, POST, OPTIONS@ and valid requested
-- header tokens (or @Content-Type@), returning empty 204 responses with a 600-second
-- max age and variation by requested method and headers. Credentials are never granted.
-- Disallowed WebSocket Origins are refused before acquiring a connection slot;
-- headerless clients remain supported. This policy is not authentication. Use a
-- trusted network or an authenticating reverse proxy. Hosts mounting 'combinedApp'
-- directly must enforce the documented configuration constraints themselves.
-- Same-origin reads need no origin list; browser control POSTs must explicitly
-- allow their page origin, even in same-origin deployments.
--
-- == HTTP errors
--
-- Error bodies contain a human-readable @error@, a stable @code@, and optional
-- context. Unknown paths return 404 @not_found@; unknown @/metrics/:id@ processors
-- return 404 @processor_not_found@ with @processor@; plain HTTP @/ws@ returns 404
-- @websocket_upgrade_required@ when WebSockets are enabled. Preflight and upgrade
-- origin refusals return 403 @origin_not_allowed@. Unsupported preflight methods
-- return 403 @cors_method_not_allowed@; invalid requested header lists return 403
-- @cors_headers_not_allowed@. Existing error members, statuses and content types
-- are preserved, and @code@ is an additive member. 'errorResponse' protects its
-- reserved @error@ and @code@ members from overrides by context.
--
-- == WebSocket Protocol
--
-- Clients can send:
--
-- * @{"type": "subscribe_all"}@ - Subscribe to all processor updates
-- * @{"type": "subscribe", "processors": ["id1", "id2"]}@ - Subscribe to specific processors
-- * @{"type": "unsubscribe", "processors": ["id1"]}@ - Unsubscribe from processors
-- * @{"type": "ping"}@ - Keepalive ping
--
-- Server sends:
--
-- * @{"type": "snapshot", "metrics": {...}}@ - Full metrics snapshot
-- * @{"type": "update", "processor": "id", "metrics": {...}}@ - Single processor update
-- * @{"type": "terminal", "processor": "id", "status": "stopped"}@ - Processor left the live registry
-- * @{"type": "pong"}@ - Response to ping
-- * @{"type": "goodbye"}@ - Server shutting down
module Shibuya.Metrics
  ( -- * Server Lifecycle
    startMetricsServer,
    startMetricsServerWithDeps,
    stopMetricsServer,
    withMetricsServer,
    combinedApp,

    -- * Configuration
    MetricsServerConfig (..),
    defaultConfig,

    -- * Host Application Helpers
    corsMiddleware,
    errorResponse,

    -- * Server Handle
    MetricsServer (..),

    -- * Health Check Types
    DependencyCheck,
    DependencyStatus (..),
    LivenessStatus (..),
    ReadinessStatus (..),
    ApplicationStatus (..),
    ProcessorHealth (..),
    HealthConfig (..),
    defaultHealthConfig,

    -- * WebSocket Protocol Types
    ClientMessage (..),
    ProcessorTerminalStatus (..),
    ServerMessage (..),
  )
where

import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Cors (corsMiddleware)
import Shibuya.Metrics.Error (errorResponse)
import Shibuya.Metrics.Health
  ( ApplicationStatus (..),
    DependencyCheck,
    DependencyStatus (..),
    HealthConfig (..),
    LivenessStatus (..),
    ProcessorHealth (..),
    ReadinessStatus (..),
    defaultHealthConfig,
  )
import Shibuya.Metrics.Server (combinedApp, startMetricsServer, startMetricsServerWithDeps, stopMetricsServer, withMetricsServer)
import Shibuya.Metrics.Types (ClientMessage (..), MetricsServer (..), ProcessorTerminalStatus (..), ServerMessage (..))
