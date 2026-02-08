-- | Metrics web server for Shibuya queue processing framework.
--
-- This module provides HTTP/JSON, Prometheus, and WebSocket endpoints
-- for exposing Shibuya processor metrics.
--
-- == Quick Start
--
-- @
-- import Shibuya.App (runApp, AppHandle)
-- import Shibuya.Metrics
--
-- main :: IO ()
-- main = do
--   -- Start your Shibuya app...
--   Right appHandle <- runEff $ runApp ...
--
--   -- Start metrics server on port 9090
--   withMetricsServer defaultConfig appHandle.master $ \\server -> do
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
-- * @{"type": "pong"}@ - Response to ping
-- * @{"type": "goodbye"}@ - Server shutting down
module Shibuya.Metrics
  ( -- * Server Lifecycle
    startMetricsServer,
    startMetricsServerWithDeps,
    stopMetricsServer,
    withMetricsServer,

    -- * Configuration
    MetricsServerConfig (..),
    defaultConfig,

    -- * Server Handle
    MetricsServer (..),

    -- * Health Check Types
    DependencyCheck,
    DependencyStatus (..),
    LivenessStatus (..),
    ReadinessStatus (..),
    ProcessorHealth (..),
    HealthConfig (..),
    defaultHealthConfig,

    -- * WebSocket Protocol Types
    ClientMessage (..),
    ServerMessage (..),
  )
where

import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Health
  ( DependencyCheck,
    DependencyStatus (..),
    HealthConfig (..),
    LivenessStatus (..),
    ProcessorHealth (..),
    ReadinessStatus (..),
    defaultHealthConfig,
  )
import Shibuya.Metrics.Server (startMetricsServer, startMetricsServerWithDeps, stopMetricsServer, withMetricsServer)
import Shibuya.Metrics.Types (ClientMessage (..), MetricsServer (..), ServerMessage (..))
