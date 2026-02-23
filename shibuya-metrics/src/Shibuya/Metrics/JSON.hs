-- | JSON HTTP endpoints for metrics and health checks.
module Shibuya.Metrics.JSON
  ( jsonApp,
    jsonAppWithHealth,
  )
where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Network.HTTP.Types
  ( Status,
    hContentType,
    status200,
    status404,
    status503,
  )
import Network.Wai (Application, Response, pathInfo, responseLBS)
import Shibuya.Metrics.Health
  ( DependencyCheck,
    HealthConfig,
    LivenessStatus (..),
    ReadinessStatus (..),
    checkDetailedHealth,
    checkLiveness,
    checkReadiness,
    defaultHealthConfig,
  )
import Shibuya.Runner.Master (Master, getAllMetricsIO, getProcessorMetricsIO)
import Shibuya.Runner.Metrics (ProcessorId (..))

-- | WAI application for JSON endpoints (without dependency checks).
-- Handles:
--   GET /metrics       - all processor metrics
--   GET /metrics/:id   - single processor metrics
--   GET /health        - detailed health status
--   GET /health/live   - liveness probe
--   GET /health/ready  - readiness probe
jsonApp :: Master -> Application
jsonApp master = jsonAppWithHealth defaultHealthConfig master []

-- | WAI application for JSON endpoints with dependency checks.
jsonAppWithHealth :: HealthConfig -> Master -> [DependencyCheck] -> Application
jsonAppWithHealth config master depChecks req respond = do
  let path = pathInfo req
  response <- routeRequest config master depChecks path
  respond response

routeRequest :: HealthConfig -> Master -> [DependencyCheck] -> [Text] -> IO Response
routeRequest config master depChecks path = case path of
  -- GET /metrics - all processor metrics
  ["metrics"] -> do
    metrics <- getAllMetricsIO master
    pure $ jsonResponse status200 $ encode metrics
  -- GET /metrics/:id - single processor metrics
  ["metrics", procIdText] -> do
    let procId = ProcessorId procIdText
    mMetrics <- getProcessorMetricsIO master procId
    case mMetrics of
      Just m -> pure $ jsonResponse status200 $ encode m
      Nothing ->
        pure $
          jsonResponse status404 $
            encode $
              object
                [ "error" .= ("Processor not found" :: Text),
                  "processor" .= procIdText
                ]
  -- GET /health/live - liveness probe (fast, simple)
  ["health", "live"] -> do
    liveness <- checkLiveness config master
    let LivenessStatus {alive} = liveness
        status = if alive then status200 else status503
    pure $ jsonResponse status $ encode liveness
  -- GET /health/ready - readiness probe (checks processors and dependencies)
  ["health", "ready"] -> do
    readiness <- checkReadiness config master depChecks
    let ReadinessStatus {ready} = readiness
        status = if ready then status200 else status503
    pure $ jsonResponse status $ encode readiness
  -- GET /health - detailed health status (for debugging)
  ["health"] -> do
    (readiness, metrics) <- checkDetailedHealth config master depChecks
    let ReadinessStatus {ready} = readiness
        status = if ready then status200 else status503
    pure $
      jsonResponse status $
        encode $
          object
            [ "status" .= readiness,
              "processors" .= metrics
            ]
  -- Not found
  _ ->
    pure $
      jsonResponse status404 $
        encode $
          object ["error" .= ("Not found" :: Text)]

jsonResponse :: Status -> LBS.ByteString -> Response
jsonResponse status = responseLBS status [(hContentType, "application/json")]
