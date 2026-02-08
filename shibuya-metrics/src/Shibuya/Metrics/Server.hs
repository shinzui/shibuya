-- | Unified metrics web server combining JSON, Prometheus, and WebSocket endpoints.
module Shibuya.Metrics.Server
  ( -- * Server Lifecycle
    startMetricsServer,
    startMetricsServerWithDeps,
    stopMetricsServer,
    withMetricsServer,

    -- * Re-exports
    MetricsServer (..),
    MetricsServerConfig (..),
    defaultConfig,
    DependencyCheck,
  )
where

import Control.Concurrent.Async (async, cancel)
import Control.Exception (bracket)
import Data.Aeson (encode, object, (.=))
import Data.Text (Text)
import Network.HTTP.Types (hContentType, status404)
import Network.Wai (Application, Response, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Health (DependencyCheck, HealthConfig (..))
import Shibuya.Metrics.JSON (jsonAppWithHealth)
import Shibuya.Metrics.Prometheus (prometheusApp)
import Shibuya.Metrics.Types (MetricsServer (..))
import Shibuya.Metrics.WebSocket (WebSocketState, newWebSocketState, websocketApp)
import Shibuya.Runner.Master (Master)

-- | Start the metrics server without dependency checks.
-- Returns a handle that can be used to stop the server.
startMetricsServer :: MetricsServerConfig -> Master -> IO MetricsServer
startMetricsServer config master = startMetricsServerWithDeps config master []

-- | Start the metrics server with dependency checks for health endpoints.
-- Returns a handle that can be used to stop the server.
startMetricsServerWithDeps ::
  MetricsServerConfig ->
  Master ->
  [DependencyCheck] ->
  IO MetricsServer
startMetricsServerWithDeps config master depChecks = do
  wsState <- newWebSocketState config.wsMaxConnections
  let app = combinedApp config master wsState depChecks
      settings =
        Warp.setPort config.port $
          Warp.setHost "*" $
            Warp.defaultSettings
  serverAsync <- async $ Warp.runSettings settings app
  pure
    MetricsServer
      { serverThread = serverAsync,
        serverPort = config.port
      }

-- | Stop the metrics server.
stopMetricsServer :: MetricsServer -> IO ()
stopMetricsServer server = cancel server.serverThread

-- | Run an action with a metrics server, ensuring cleanup.
withMetricsServer ::
  MetricsServerConfig ->
  Master ->
  (MetricsServer -> IO a) ->
  IO a
withMetricsServer config master action =
  bracket
    (startMetricsServer config master)
    stopMetricsServer
    action

-- | Combined WAI application routing to all endpoints.
combinedApp ::
  MetricsServerConfig ->
  Master ->
  WebSocketState ->
  [DependencyCheck] ->
  Application
combinedApp config master wsState depChecks =
  -- Handle WebSocket upgrade first
  WaiWS.websocketsOr
    WS.defaultConnectionOptions
    (websocketApp config master wsState)
    (httpApp config master depChecks)

-- | HTTP application routing based on path.
httpApp :: MetricsServerConfig -> Master -> [DependencyCheck] -> Application
httpApp config master depChecks req respond = do
  let path = pathInfo req
      healthConfig =
        HealthConfig
          { livenessTimeoutMicros = config.livenessTimeoutMicros,
            stuckThreshold = config.stuckThreshold
          }
      jsonHandler = jsonAppWithHealth healthConfig master depChecks
  case path of
    -- Prometheus endpoint
    ["metrics", "prometheus"]
      | config.enablePrometheus ->
          prometheusApp master req respond
    -- JSON endpoints (metrics and health)
    ["metrics"]
      | config.enableJSON ->
          jsonHandler req respond
    ["metrics", _]
      | config.enableJSON ->
          jsonHandler req respond
    ["health"]
      | config.enableJSON ->
          jsonHandler req respond
    ["health", "live"]
      | config.enableJSON ->
          jsonHandler req respond
    ["health", "ready"]
      | config.enableJSON ->
          jsonHandler req respond
    -- WebSocket path info (for documentation, actual upgrade handled above)
    ["ws"]
      | config.enableWebSocket ->
          respond $ notFoundResponse "WebSocket endpoint - use ws:// protocol"
    -- Not found
    _ -> respond $ notFoundResponse "Not found"

notFoundResponse :: Text -> Response
notFoundResponse msg =
  responseLBS
    status404
    [(hContentType, "application/json")]
    (encode $ object ["error" .= msg])
