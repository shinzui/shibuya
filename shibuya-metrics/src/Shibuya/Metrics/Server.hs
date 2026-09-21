-- | Unified metrics web server combining JSON, Prometheus, and WebSocket endpoints.
module Shibuya.Metrics.Server
  ( -- * Server Lifecycle
    startMetricsServer,
    startMetricsServerWithDeps,
    stopMetricsServer,
    withMetricsServer,
    combinedApp,

    -- * Re-exports
    MetricsServer (..),
    MetricsServerConfig (..),
    defaultConfig,
    DependencyCheck,
  )
where

import Control.Concurrent.Async (async, cancel)
import Control.Exception (bracket, finally)
import Data.Aeson (encode, object, (.=))
import Data.String (fromString)
import Data.Text (Text)
import Network.HTTP.Types (hContentType, status404)
import Network.Wai (Application, Response, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import Shibuya.App (Master)
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Health (DependencyCheck, HealthConfig (..))
import Shibuya.Metrics.JSON (jsonAppWithHealth)
import Shibuya.Metrics.Prometheus (prometheusApp)
import Shibuya.Metrics.Types (MetricsServer (..))
import Shibuya.Metrics.WebSocket (WebSocketState, newWebSocketState, shutdownWebSockets, websocketApp)

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
  validateConfig config
  wsState <- newWebSocketState config.wsMaxConnections
  let app = combinedApp config master wsState depChecks
      settings =
        Warp.setPort config.port $
          Warp.setHost
            (fromString config.host)
            Warp.defaultSettings
  serverAsync <- async $ Warp.runSettings settings app `finally` shutdownWebSockets wsState
  pure
    MetricsServer
      { serverThread = serverAsync,
        serverPort = config.port
      }

validateConfig :: MetricsServerConfig -> IO ()
validateConfig config
  | null config.host = fail "MetricsServerConfig.host must not be empty"
  | config.port < 0 = fail "MetricsServerConfig.port must be non-negative"
  | config.wsPushIntervalUs <= 0 = fail "MetricsServerConfig.wsPushIntervalUs must be positive"
  | config.wsMaxConnections <= 0 = fail "MetricsServerConfig.wsMaxConnections must be positive"
  | config.wsMaxSubscriptions <= 0 = fail "MetricsServerConfig.wsMaxSubscriptions must be positive"
  | config.livenessTimeoutMicros <= 0 = fail "MetricsServerConfig.livenessTimeoutMicros must be positive"
  | config.dependencyTimeoutMicros <= 0 = fail "MetricsServerConfig.dependencyTimeoutMicros must be positive"
  | config.stuckThreshold <= 0 = fail "MetricsServerConfig.stuckThreshold must be positive"
  | otherwise = pure ()

-- | Stop the metrics server.
stopMetricsServer :: MetricsServer -> IO ()
stopMetricsServer server = cancel server.serverThread

-- | Run an action with a metrics server, ensuring cleanup.
withMetricsServer ::
  MetricsServerConfig ->
  Master ->
  (MetricsServer -> IO a) ->
  IO a
withMetricsServer config master =
  bracket
    (startMetricsServer config master)
    stopMetricsServer

-- | Combined WAI application routing to all endpoints.
combinedApp ::
  MetricsServerConfig ->
  Master ->
  WebSocketState ->
  [DependencyCheck] ->
  Application
combinedApp config master wsState depChecks =
  if config.enableWebSocket
    then
      WaiWS.websocketsOr
        WS.defaultConnectionOptions
        (websocketApp config master wsState)
        fallback
    else fallback
  where
    fallback = httpApp config master depChecks

-- | HTTP application routing based on path.
httpApp :: MetricsServerConfig -> Master -> [DependencyCheck] -> Application
httpApp config master depChecks req respond = do
  let path = pathInfo req
      healthConfig =
        HealthConfig
          { livenessTimeoutMicros = config.livenessTimeoutMicros,
            dependencyTimeoutMicros = config.dependencyTimeoutMicros,
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
