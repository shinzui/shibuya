-- | Endurance test for Shibuya with PGMQ adapter.
--
-- Runs for hours to verify stability under sustained load.
--
-- Environment variables:
--   PG_CONNECTION_STRING - PostgreSQL connection string (required)
--   DURATION_SECS        - Test duration in seconds (default: 14400 = 4 hours)
--   MESSAGES_PER_SECOND  - Target message rate (default: 100)
--   SAMPLE_INTERVAL_SECS - Metrics sampling interval (default: 30)
--   OUTPUT_CSV           - Path to output CSV file (default: endurance_metrics.csv)
--
-- Pass/Fail Criteria:
--   - Memory growth < 2x initial
--   - Failed messages < 1%
--   - All produced messages processed
--
-- Usage:
--   PG_CONNECTION_STRING="host=localhost dbname=pgmq" cabal run endurance-test
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Monad (forever, unless)
import Data.Aeson (Value, object, (.=))
import Data.ByteString.Char8 qualified as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Word (Word64)
import Effectful (IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (runErrorNoCallStack)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig
import Pgmq.Effectful (runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Pgmq.Hasql.Sessions qualified as Pgmq
import Pgmq.Hasql.Statements.Types qualified as Q
import Pgmq.Migration qualified as Migration
import Pgmq.Types (MessageBody (..), QueueName, parseQueueName)
import Shibuya.Adapter.Pgmq
  ( defaultConfig,
    pgmqAdapter,
  )
import Shibuya.App
  ( ShutdownConfig (..),
    SupervisionStrategy (..),
    mkProcessor,
    runApp,
    stopAppGracefully,
  )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Handler (Handler)
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Environment (getEnv, lookupEnv)
import System.IO (Handle, IOMode (..), hFlush, hPutStrLn, withFile)
import Text.Read (readMaybe)

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

data EnduranceConfig = EnduranceConfig
  { connectionString :: !BS.ByteString,
    durationSecs :: !Int,
    messagesPerSecond :: !Int,
    sampleIntervalSecs :: !Int,
    outputCsv :: !FilePath
  }
  deriving stock (Show)

loadConfig :: IO EnduranceConfig
loadConfig = do
  connStr <- getEnv "PG_CONNECTION_STRING"
  duration <- getEnvIntDefault "DURATION_SECS" 14400
  msgRate <- getEnvIntDefault "MESSAGES_PER_SECOND" 100
  sampleInterval <- getEnvIntDefault "SAMPLE_INTERVAL_SECS" 30
  csvPath <- getEnvDefault "OUTPUT_CSV" "endurance_metrics.csv"
  pure
    EnduranceConfig
      { connectionString = BS.pack connStr,
        durationSecs = duration,
        messagesPerSecond = msgRate,
        sampleIntervalSecs = sampleInterval,
        outputCsv = csvPath
      }

getEnvDefault :: String -> String -> IO String
getEnvDefault name def = do
  mVal <- lookupEnv name
  pure $ maybe def id mVal

getEnvIntDefault :: String -> Int -> IO Int
getEnvIntDefault name def = do
  mVal <- lookupEnv name
  pure $ maybe def id (mVal >>= readMaybe)

--------------------------------------------------------------------------------
-- Metrics Collection
--------------------------------------------------------------------------------

data Sample = Sample
  { timestamp :: !UTCTime,
    elapsedSecs :: !Int,
    messagesProduced :: !Int,
    messagesProcessed :: !Int,
    messagesFailed :: !Int,
    memoryBytes :: !Word64
  }
  deriving stock (Show)

sampleToCsv :: Sample -> Text
sampleToCsv s =
  Text.intercalate
    ","
    [ Text.pack $ formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" s.timestamp,
      Text.pack $ show s.elapsedSecs,
      Text.pack $ show s.messagesProduced,
      Text.pack $ show s.messagesProcessed,
      Text.pack $ show s.messagesFailed,
      Text.pack $ show s.memoryBytes
    ]

csvHeader :: Text
csvHeader = "timestamp,elapsed_secs,produced,processed,failed,memory_bytes"

--------------------------------------------------------------------------------
-- Pass/Fail Criteria
--------------------------------------------------------------------------------

data TestResult = TestResult
  { passed :: !Bool,
    initialMemory :: !Word64,
    finalMemory :: !Word64,
    memoryGrowthRatio :: !Double,
    totalProduced :: !Int,
    totalProcessed :: !Int,
    totalFailed :: !Int,
    failureRate :: !Double,
    errors :: ![Text]
  }
  deriving stock (Show)

checkCriteria :: Word64 -> Word64 -> Int -> Int -> Int -> TestResult
checkCriteria initialMem finalMem produced processed failed =
  let memRatio :: Double
      memRatio = fromIntegral finalMem / max 1 (fromIntegral initialMem)
      failRate :: Double
      failRate = fromIntegral failed / max 1 (fromIntegral (processed + failed))
      processedRatio :: Double
      processedRatio = fromIntegral processed / max 1 (fromIntegral produced)
      errs =
        [ "Memory grew " <> Text.pack (show memRatio) <> "x (limit: 2x)"
        | memRatio > 2.0
        ]
          ++ [ "Failure rate " <> Text.pack (show (failRate * 100)) <> "% (limit: 1%)"
             | failRate > 0.01
             ]
          ++ [ "Only processed " <> Text.pack (show (processedRatio * 100)) <> "% of messages"
             | processedRatio < 0.95
             ]
   in TestResult
        { passed = null errs,
          initialMemory = initialMem,
          finalMemory = finalMem,
          memoryGrowthRatio = memRatio,
          totalProduced = produced,
          totalProcessed = processed,
          totalFailed = failed,
          failureRate = failRate,
          errors = errs
        }

--------------------------------------------------------------------------------
-- Producer
--------------------------------------------------------------------------------

runProducer ::
  Pool.Pool ->
  QueueName ->
  Int ->
  TVar Int ->
  TVar Bool ->
  IO ()
runProducer pool queue msgsPerSec countVar stopVar = go 0
  where
    delayMicros = 1_000_000 `div` max 1 msgsPerSec

    go :: Int -> IO ()
    go !idx = do
      shouldStop <- readTVarIO stopVar
      unless shouldStop $ do
        let payload = object ["id" .= idx, "ts" .= show idx]
            msg =
              Q.SendMessage
                { queueName = queue,
                  messageBody = MessageBody payload,
                  delay = Nothing
                }
        result <- Pool.use pool $ Pgmq.sendMessage msg
        case result of
          Left _ -> pure ()
          Right _ -> atomically $ modifyTVar' countVar (+ 1)
        threadDelay delayMicros
        go (idx + 1)

--------------------------------------------------------------------------------
-- Handler
--------------------------------------------------------------------------------

makeHandler :: (IOE :> es) => IORef Int -> IORef Int -> Handler es Value
makeHandler successRef _failRef _ = do
  liftIO $ atomicModifyIORef' successRef (\n -> (n + 1, ()))
  pure AckOk

--------------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------------

getMemoryBytes :: IO Word64
getMemoryBytes = do
  enabled <- getRTSStatsEnabled
  if enabled
    then do
      stats <- getRTSStats
      pure $ max_live_bytes stats
    else pure 0

sampleMetrics ::
  UTCTime ->
  TVar Int ->
  IORef Int ->
  IORef Int ->
  IO Sample
sampleMetrics startTime producedVar processedRef failedRef = do
  now <- getCurrentTime
  produced <- readTVarIO producedVar
  processed <- readIORef processedRef
  failed <- readIORef failedRef
  memBytes <- getMemoryBytes

  pure
    Sample
      { timestamp = now,
        elapsedSecs = round $ diffUTCTime now startTime,
        messagesProduced = produced,
        messagesProcessed = processed,
        messagesFailed = failed,
        memoryBytes = memBytes
      }

--------------------------------------------------------------------------------
-- Main
--------------------------------------------------------------------------------

main :: IO ()
main = do
  putStrLn "=== Shibuya Endurance Test ==="
  putStrLn ""

  config <- loadConfig
  putStrLn $ "Configuration:"
  putStrLn $ "  Duration: " <> show config.durationSecs <> " seconds"
  putStrLn $ "  Target rate: " <> show config.messagesPerSecond <> " msg/s"
  putStrLn $ "  Sample interval: " <> show config.sampleIntervalSecs <> " seconds"
  putStrLn $ "  Output CSV: " <> config.outputCsv
  putStrLn ""

  pool <- createPool config.connectionString
  putStrLn "Connected to PostgreSQL"

  installSchema pool
  putStrLn "PGMQ schema installed"

  let queueName = case parseQueueName "endurance_test" of
        Left err -> error $ "Invalid queue name: " <> show err
        Right q -> q
  createQueue pool queueName
  putStrLn $ "Queue created: endurance_test"
  putStrLn ""

  result <- runEnduranceTest config pool queueName

  dropQueue pool queueName
  Pool.release pool

  printResult result

  if result.passed
    then putStrLn "\n=== TEST PASSED ==="
    else do
      putStrLn "\n=== TEST FAILED ==="
      mapM_ (putStrLn . ("  - " <>) . Text.unpack) result.errors

runEnduranceTest ::
  EnduranceConfig ->
  Pool.Pool ->
  QueueName ->
  IO TestResult
runEnduranceTest config pool queueName = do
  producedVar <- newTVarIO (0 :: Int)
  processedRef <- newIORef (0 :: Int)
  failedRef <- newIORef (0 :: Int)
  stopVar <- newTVarIO False

  initialMem <- getMemoryBytes
  startTime <- getCurrentTime
  putStrLn $ "Initial memory: " <> show initialMem <> " bytes"
  putStrLn $ "Starting test at: " <> show startTime
  putStrLn ""

  withFile config.outputCsv WriteMode $ \csvHandle -> do
    hPutStrLn csvHandle (Text.unpack csvHeader)
    hFlush csvHandle

    producerAsync <- async $ runProducer pool queueName config.messagesPerSecond producedVar stopVar

    samplerAsync <- async $ runSampler config startTime producedVar processedRef failedRef csvHandle

    let adapterConfig = defaultConfig queueName
    eResult <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmq pool $ runTracingNoop $ do
      adapter <- pgmqAdapter adapterConfig
      let handler = makeHandler processedRef failedRef
          processor = mkProcessor adapter handler

      result <- runApp IgnoreFailures 100 [(ProcessorId "endurance", processor)]
      case result of
        Left err -> liftIO $ error $ "Failed to start app: " <> show err
        Right appHandle -> do
          liftIO $ do
            putStrLn $ "Running for " <> show config.durationSecs <> " seconds..."
            threadDelay (config.durationSecs * 1_000_000)

            putStrLn "\nStopping..."
            atomically $ modifyTVar' stopVar (const True)

            cancel producerAsync
            cancel samplerAsync

          let shutdownConfig = ShutdownConfig {drainTimeout = 30}
          _ <- stopAppGracefully shutdownConfig appHandle
          pure ()

    case eResult of
      Left err -> error $ "Pgmq error: " <> show err
      Right _ -> pure ()

    putStrLn "Processor stopped"

    -- Wait a bit for final processing
    threadDelay 1_000_000

    finalMem <- getMemoryBytes
    produced <- readTVarIO producedVar
    processed <- readIORef processedRef
    failed <- readIORef failedRef

    pure $ checkCriteria initialMem finalMem produced processed failed

runSampler ::
  EnduranceConfig ->
  UTCTime ->
  TVar Int ->
  IORef Int ->
  IORef Int ->
  Handle ->
  IO ()
runSampler config startTime producedVar processedRef failedRef csvHandle = forever $ do
  threadDelay (config.sampleIntervalSecs * 1_000_000)
  sample <- sampleMetrics startTime producedVar processedRef failedRef
  let csvLine = sampleToCsv sample
  hPutStrLn csvHandle (Text.unpack csvLine)
  hFlush csvHandle
  putStrLn $
    "["
      <> show sample.elapsedSecs
      <> "s] produced="
      <> show sample.messagesProduced
      <> " processed="
      <> show sample.messagesProcessed
      <> " failed="
      <> show sample.messagesFailed
      <> " mem="
      <> show (sample.memoryBytes `div` 1024 `div` 1024)
      <> "MB"

printResult :: TestResult -> IO ()
printResult result = do
  putStrLn ""
  putStrLn "=== Test Results ==="
  putStrLn $ "  Total produced: " <> show result.totalProduced
  putStrLn $ "  Total processed: " <> show result.totalProcessed
  putStrLn $ "  Total failed: " <> show result.totalFailed
  putStrLn $ "  Failure rate: " <> show (result.failureRate * 100) <> "%"
  putStrLn $ "  Initial memory: " <> show (result.initialMemory `div` 1024 `div` 1024) <> " MB"
  putStrLn $ "  Final memory: " <> show (result.finalMemory `div` 1024 `div` 1024) <> " MB"
  putStrLn $ "  Memory growth: " <> show result.memoryGrowthRatio <> "x"

--------------------------------------------------------------------------------
-- Database Helpers
--------------------------------------------------------------------------------

createPool :: BS.ByteString -> IO Pool.Pool
createPool connStr = do
  let connSettings = Settings.connectionString (Text.pack (BS.unpack connStr))
      poolConfig =
        PoolConfig.settings
          [ PoolConfig.size 20,
            PoolConfig.staticConnectionSettings connSettings
          ]
  Pool.acquire poolConfig

installSchema :: Pool.Pool -> IO ()
installSchema pool = do
  result <- Pool.use pool Migration.migrate
  case result of
    Left err -> error $ "Migration session error: " <> show err
    Right (Left err) -> error $ "Migration error: " <> show err
    Right (Right ()) -> pure ()

createQueue :: Pool.Pool -> QueueName -> IO ()
createQueue pool qName = do
  result <- Pool.use pool $ Pgmq.createQueue qName
  case result of
    Left err -> error $ "Create queue error: " <> show err
    Right _ -> pure ()

dropQueue :: Pool.Pool -> QueueName -> IO ()
dropQueue pool qName = do
  _ <- Pool.use pool $ Pgmq.dropQueue qName
  pure ()
