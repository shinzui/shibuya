-- | Prometheus metrics endpoint.
module Shibuya.Metrics.Prometheus
  ( prometheusApp,
  )
where

import Data.ByteString.Builder qualified as Builder
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Network.HTTP.Types (hContentType, status200)
import Network.Wai (Application, Response, responseLBS)
import Shibuya.Runner.Master (Master, getAllMetricsIO)
import Shibuya.Runner.Metrics
  ( MetricsMap,
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
  )

-- | WAI application for Prometheus metrics endpoint.
-- Handles: GET /metrics/prometheus
prometheusApp :: Master -> Application
prometheusApp master _req respond = do
  metrics <- getAllMetricsIO master
  let body = renderPrometheusMetrics metrics
  respond $
    responseLBS
      status200
      [(hContentType, "text/plain; version=0.0.4; charset=utf-8")]
      (Builder.toLazyByteString body)

-- | Render metrics in Prometheus text format.
renderPrometheusMetrics :: MetricsMap -> Builder.Builder
renderPrometheusMetrics metrics =
  mconcat
    [ renderHelp "shibuya_messages_received_total" "Total messages received by processor",
      renderType "shibuya_messages_received_total" "counter",
      renderGaugeMetrics "shibuya_messages_received_total" (fromIntegral . (.stats.received)) metrics,
      renderHelp "shibuya_messages_processed_total" "Total messages successfully processed",
      renderType "shibuya_messages_processed_total" "counter",
      renderGaugeMetrics "shibuya_messages_processed_total" (fromIntegral . (.stats.processed)) metrics,
      renderHelp "shibuya_messages_dropped_total" "Total messages dropped due to backpressure",
      renderType "shibuya_messages_dropped_total" "counter",
      renderGaugeMetrics "shibuya_messages_dropped_total" (fromIntegral . (.stats.dropped)) metrics,
      renderHelp "shibuya_messages_failed_total" "Total messages that failed processing",
      renderType "shibuya_messages_failed_total" "counter",
      renderGaugeMetrics "shibuya_messages_failed_total" (fromIntegral . (.stats.failed)) metrics,
      renderHelp "shibuya_processor_state" "Current processor state (1=idle, 2=processing, 3=failed, 4=stopped)",
      renderType "shibuya_processor_state" "gauge",
      renderGaugeMetrics "shibuya_processor_state" (fromIntegral . stateToInt . (.state)) metrics,
      renderHelp "shibuya_processor_in_flight" "Number of messages currently being processed",
      renderType "shibuya_processor_in_flight" "gauge",
      renderGaugeMetrics "shibuya_processor_in_flight" (fromIntegral . inFlightCount . (.state)) metrics
    ]

renderHelp :: Text -> Text -> Builder.Builder
renderHelp name help =
  Builder.byteString "# HELP "
    <> Builder.byteString (Text.encodeUtf8 name)
    <> Builder.char8 ' '
    <> Builder.byteString (Text.encodeUtf8 help)
    <> Builder.char8 '\n'

renderType :: Text -> Text -> Builder.Builder
renderType name typ =
  Builder.byteString "# TYPE "
    <> Builder.byteString (Text.encodeUtf8 name)
    <> Builder.char8 ' '
    <> Builder.byteString (Text.encodeUtf8 typ)
    <> Builder.char8 '\n'

renderGaugeMetrics :: Text -> (ProcessorMetrics -> Double) -> MetricsMap -> Builder.Builder
renderGaugeMetrics name getValue metrics =
  Map.foldMapWithKey (renderMetric name getValue) metrics

renderMetric :: Text -> (ProcessorMetrics -> Double) -> ProcessorId -> ProcessorMetrics -> Builder.Builder
renderMetric name getValue (ProcessorId pid) pm =
  Builder.byteString (Text.encodeUtf8 name)
    <> Builder.byteString "{processor=\""
    <> Builder.byteString (Text.encodeUtf8 $ escapeLabel pid)
    <> Builder.byteString "\"} "
    <> Builder.doubleDec (getValue pm)
    <> Builder.char8 '\n'

-- | Escape special characters in Prometheus label values.
escapeLabel :: Text -> Text
escapeLabel = Text.concatMap escapeChar
  where
    escapeChar '\\' = "\\\\"
    escapeChar '"' = "\\\""
    escapeChar '\n' = "\\n"
    escapeChar c = Text.singleton c

-- | Convert processor state to integer for Prometheus.
stateToInt :: ProcessorState -> Int
stateToInt Idle = 1
stateToInt (Processing _ _) = 2
stateToInt (Failed _ _) = 3
stateToInt Stopped = 4

-- | Get in-flight count from processor state.
inFlightCount :: ProcessorState -> Int
inFlightCount (Processing count _) = count
inFlightCount _ = 0
