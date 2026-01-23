-- | JSON HTTP endpoints for metrics.
module Shibuya.Metrics.JSON
  ( jsonApp,
  )
where

import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types
  ( Status,
    hContentType,
    status200,
    status404,
  )
import Network.Wai (Application, Request, Response, pathInfo, responseLBS)
import Shibuya.Runner.Master (Master, getAllMetricsIO, getProcessorMetricsIO)
import Shibuya.Runner.Metrics (ProcessorId (..))

-- | WAI application for JSON endpoints.
-- Handles:
--   GET /metrics       - all processor metrics
--   GET /metrics/:id   - single processor metrics
--   GET /health        - health check
jsonApp :: Master -> Application
jsonApp master req respond = do
  let path = pathInfo req
  response <- routeRequest master path
  respond response

routeRequest :: Master -> [Text] -> IO Response
routeRequest master path = case path of
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
  -- GET /health - health check
  ["health"] -> do
    metrics <- getAllMetricsIO master
    let processorCount = Map.size metrics
    pure $
      jsonResponse status200 $
        encode $
          object
            [ "status" .= ("ok" :: Text),
              "processorCount" .= processorCount
            ]
  -- Not found
  _ ->
    pure $
      jsonResponse status404 $
        encode $
          object ["error" .= ("Not found" :: Text)]

jsonResponse :: Status -> LBS.ByteString -> Response
jsonResponse status body =
  responseLBS status [(hContentType, "application/json")] body
