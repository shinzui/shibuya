-- | Unified metrics web server combining JSON, Prometheus, and WebSocket endpoints.
module Shibuya.Metrics.Server
  ( -- * Server Lifecycle
    startMetricsServer,
    stopMetricsServer,
    withMetricsServer,

    -- * Re-exports
    MetricsServer (..),
    MetricsServerConfig (..),
    defaultConfig,
  )
where

import Control.Concurrent.Async (async, cancel, wait)
import Control.Exception (bracket)
import Data.Aeson (encode, object, (.=))
import Data.Text (Text)
import Network.HTTP.Types (hContentType, status404)
import Network.Wai (Application, Request, Response, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.JSON (jsonApp)
import Shibuya.Metrics.Prometheus (prometheusApp)
import Shibuya.Metrics.Types (MetricsServer (..))
import Shibuya.Metrics.WebSocket (WebSocketState, newWebSocketState, websocketApp)
import Shibuya.Runner.Master (Master)

-- | Start the metrics server.
-- Returns a handle that can be used to stop the server.
startMetricsServer :: MetricsServerConfig -> Master -> IO MetricsServer
startMetricsServer config master = do
  wsState <- newWebSocketState config.wsMaxConnections
  let app = combinedApp config master wsState
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
  Application
combinedApp config master wsState =
  -- Handle WebSocket upgrade first
  WaiWS.websocketsOr
    WS.defaultConnectionOptions
    (websocketApp config master wsState)
    (httpApp config master)

-- | HTTP application routing based on path.
httpApp :: MetricsServerConfig -> Master -> Application
httpApp config master req respond = do
  let path = pathInfo req
  case path of
    -- Prometheus endpoint
    ["metrics", "prometheus"]
      | config.enablePrometheus ->
          prometheusApp master req respond
    -- JSON endpoints
    ["metrics"]
      | config.enableJSON ->
          jsonApp master req respond
    ["metrics", _]
      | config.enableJSON ->
          jsonApp master req respond
    ["health"]
      | config.enableJSON ->
          jsonApp master req respond
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
