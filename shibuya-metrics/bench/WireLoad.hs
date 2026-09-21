-- | EP-45 real-wire health polling and WebSocket churn fixture.
module Main (main) where

import Control.Concurrent.NQE.Supervisor (Strategy (IgnoreAll))
import Control.Concurrent.STM (atomically, check, readTVar)
import Control.Exception (bracket, evaluate)
import Control.Monad (replicateM)
import Data.Aeson (ToJSON, encode)
import Data.ByteString.Lazy qualified as LBS
import Data.List (sort)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Word (Word64)
import Effectful (runEff)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types.Status (status200)
import Network.Wai.Handler.Warp qualified as Warp
import Network.WebSockets qualified as WS
import Shibuya.App (Master, ProcessorId (..))
import Shibuya.Core.Metrics (newMetricsHandle)
import Shibuya.Internal.Runner.Master (markMasterRunning, registerProcessor, startMaster, stopMaster)
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Server (combinedApp)
import Shibuya.Metrics.WebSocket (WebSocketState (..), newWebSocketState)
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.Mem (performMajorGC)
import System.Timeout (timeout)
import Text.Read (readMaybe)

data Scenario = HealthPolling | WebSocketChurn
  deriving stock (Eq, Show)

data Report = Report
  { schemaVersion :: !Int,
    scenario :: !String,
    iterations :: !Int,
    completed :: !Int,
    errors :: !Int,
    elapsedSeconds :: !Double,
    operationsPerSecond :: !Double,
    latencyP50Micros :: !Double,
    latencyP95Micros :: !Double,
    latencyP99Micros :: !Double,
    retainedBytes :: !Word64,
    maxLiveBytes :: !Word64,
    finalWebSocketConnections :: !Int
  }
  deriving stock (Generic)
  deriving anyclass (ToJSON)

main :: IO ()
main = do
  selected <- loadScenario
  defaultIterations <- pure $ if selected == HealthPolling then 5_000 else 500
  count <- envInt "ITERATIONS" defaultIterations
  output <- maybe "metrics-wire-load.json" id <$> lookupEnv "OUTPUT_JSON"
  report <- withMaster $ \master -> do
    registerIdleProcessor master
    wsState <- newWebSocketState defaultConfig.wsMaxConnections
    let config = defaultConfig {wsPushIntervalUs = 10_000}
        app = combinedApp config master wsState []
    Warp.testWithApplication (pure app) $ \port -> runScenario selected count port wsState
  LBS.writeFile output (encode report <> "\n")
  LBS.putStr (encode report <> "\n")
  if report.completed == report.iterations && report.errors == 0 && report.finalWebSocketConnections == 0
    then pure ()
    else exitFailure

loadScenario :: IO Scenario
loadScenario = do
  value <- maybe "health" id <$> lookupEnv "SCENARIO"
  case value of
    "health" -> pure HealthPolling
    "websocket" -> pure WebSocketChurn
    other -> error $ "SCENARIO must be health or websocket, got: " <> other

envInt :: String -> Int -> IO Int
envInt key fallback = maybe fallback id . (>>= readMaybe) <$> lookupEnv key

withMaster :: (Master -> IO a) -> IO a
withMaster = bracket acquire release
  where
    acquire = runEff $ do
      master <- startMaster IgnoreAll
      markMasterRunning master
      pure master
    release master = runEff $ stopMaster master

registerIdleProcessor :: Master -> IO ()
registerIdleProcessor master = do
  now <- getCurrentTime
  metrics <- newMetricsHandle now
  runEff $ registerProcessor master (ProcessorId "wire-load") metrics

runScenario :: Scenario -> Int -> Int -> WebSocketState -> IO Report
runScenario selected count port wsState = do
  start <- getCurrentTime
  latencies <- case selected of
    HealthPolling -> runHealthPolling count port
    WebSocketChurn -> runWebSocketChurn count port
  finish <- getCurrentTime
  remaining <- waitForNoConnections wsState
  (retained, highWater) <- getMemoryBytes
  let elapsed = realToFrac (diffUTCTime finish start)
      completedCount = length latencies
  pure
    Report
      { schemaVersion = 1,
        scenario = case selected of HealthPolling -> "health-polling"; WebSocketChurn -> "websocket-churn",
        iterations = count,
        completed = completedCount,
        errors = count - completedCount,
        elapsedSeconds = elapsed,
        operationsPerSecond = fromIntegral completedCount / max 0.000_001 elapsed,
        latencyP50Micros = percentile 0.50 latencies,
        latencyP95Micros = percentile 0.95 latencies,
        latencyP99Micros = percentile 0.99 latencies,
        retainedBytes = retained,
        maxLiveBytes = highWater,
        finalWebSocketConnections = remaining
      }

runHealthPolling :: Int -> Int -> IO [Word64]
runHealthPolling count port = do
  manager <- HTTP.newManager HTTP.defaultManagerSettings
  let request = HTTP.parseRequest_ $ "http://127.0.0.1:" <> show port <> "/health/ready"
  replicateM count $ timedMicros $ do
    response <- HTTP.httpLbs request manager
    if HTTP.responseStatus response /= status200
      then error $ "Unexpected health status: " <> show (HTTP.responseStatus response)
      else evaluate (LBS.length (HTTP.responseBody response)) >> pure ()

runWebSocketChurn :: Int -> Int -> IO [Word64]
runWebSocketChurn count port =
  replicateM count $
    timedMicros $
      WS.runClient "127.0.0.1" port "/ws" $ \connection -> do
        payload <- WS.receiveData connection :: IO LBS.ByteString
        evaluate (LBS.length payload) >> pure ()

timedMicros :: IO a -> IO Word64
timedMicros action = do
  start <- getMonotonicTimeNSec
  _ <- action
  finish <- getMonotonicTimeNSec
  pure $ (finish - start) `div` 1_000

percentile :: Double -> [Word64] -> Double
percentile _ [] = 0
percentile quantile values =
  let ordered = sort values
      index = min (length ordered - 1) (ceiling (quantile * fromIntegral (length ordered)) - 1)
   in fromIntegral (ordered !! max 0 index)

waitForNoConnections :: WebSocketState -> IO Int
waitForNoConnections wsState = do
  released <- timeout 5_000_000 $ atomically $ do
    count <- readTVar wsState.connectionCount
    check $ count == 0
  case released of
    Nothing -> readTVarIO wsState.connectionCount
    Just () -> pure 0
  where
    readTVarIO variable = atomically $ readTVar variable

getMemoryBytes :: IO (Word64, Word64)
getMemoryBytes = do
  enabled <- getRTSStatsEnabled
  if enabled
    then do
      performMajorGC
      stats <- getRTSStats
      pure (gcdetails_live_bytes stats.gc, max_live_bytes stats)
    else pure (0, 0)
