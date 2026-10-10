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
import Network.Wai (Application, responseLBS)
import Shibuya.App (Master, getAllMetricsIO)
import Shibuya.Core.Metrics
  ( InFlightInfo (..),
    MetricsMap,
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
  )
import Shibuya.Core.Metrics qualified as Metrics

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
      renderHelp "shibuya_messages_failed_total" "Total messages that failed processing",
      renderType "shibuya_messages_failed_total" "counter",
      renderGaugeMetrics "shibuya_messages_failed_total" (fromIntegral . (.stats.failed)) metrics,
      renderHelp "shibuya_processor_state" "Current processor state (1=idle, 2=processing, 3=failed, 4=stopped)",
      renderType "shibuya_processor_state" "gauge",
      renderGaugeMetrics "shibuya_processor_state" (fromIntegral . stateToInt . (.state)) metrics,
      renderHelp "shibuya_processor_in_flight" "Number of messages currently being processed",
      renderType "shibuya_processor_in_flight" "gauge",
      renderGaugeMetrics "shibuya_processor_in_flight" (fromIntegral . inFlightCount . (.state)) metrics,
      renderHelp "shibuya_message_processing_seconds" "Processing attempt duration including finalization retries (one observation per message or emitted batch)",
      renderType "shibuya_message_processing_seconds" "histogram",
      Map.foldMapWithKey renderLatency metrics,
      renderHelp "shibuya_processor_oldest_in_flight_seconds" "Age of oldest in-flight processing attempt",
      renderType "shibuya_processor_oldest_in_flight_seconds" "gauge",
      Map.foldMapWithKey renderOldest metrics
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
renderGaugeMetrics name getValue = Map.foldMapWithKey (renderMetric name getValue)

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
stateToInt (Processing _ _ _) = 2
stateToInt (Failed _ _) = 3
stateToInt Stopped = 4

-- | Get in-flight count from processor state.
inFlightCount :: ProcessorState -> Int
inFlightCount (Processing info _ _) = info.inFlight
inFlightCount _ = 0

renderLatency :: ProcessorId -> ProcessorMetrics -> Builder.Builder
renderLatency (ProcessorId pid) pm = case pm.latency of
  Nothing -> mempty
  Just summary ->
    let labels = Builder.byteString "{processor=\"" <> Builder.byteString (Text.encodeUtf8 (escapeLabel pid))
        prefix suffix = Builder.byteString "shibuya_message_processing_seconds" <> Builder.byteString suffix <> labels
        bucket label count =
          prefix "_bucket"
            <> Builder.byteString "\",le=\""
            <> Builder.byteString (Text.encodeUtf8 label)
            <> Builder.byteString "\"} "
            <> Builder.integerDec count
            <> Builder.char8 '\n'
        scalar suffix value = prefix suffix <> Builder.byteString "\"} " <> value <> Builder.char8 '\n'
     in mconcat (zipWith bucket Metrics.latencyBucketLabels (map (.count) summary.buckets ++ [summary.count]))
          <> scalar "_sum" (Builder.doubleDec summary.sumSeconds)
          <> scalar "_count" (Builder.integerDec summary.count)

renderOldest :: ProcessorId -> ProcessorMetrics -> Builder.Builder
renderOldest pid pm = case pm.oldestInFlight of
  Nothing -> mempty
  Just oldest -> renderMetric "shibuya_processor_oldest_in_flight_seconds" (const oldest.ageSeconds) pid pm
