module BenchConfig
  ( BenchConfig (..),
    PayloadSize (..),
    loadConfig,
    payloadBytes,
    parseBatchSizes,
    parsePayloadSizes,
  )
where

import Control.DeepSeq (NFData)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.Char (toLower)
import Data.List (nub)
import Data.Maybe (fromMaybe)
import GHC.Generics (Generic)
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Payload size categories for benchmarks
data PayloadSize
  = Small -- 100 bytes
  | Medium -- 10KB
  | Large -- 100KB
  deriving stock (Show, Eq, Ord, Generic, Enum, Bounded)
  deriving anyclass (NFData)

-- | Get approximate byte count for each payload size
payloadBytes :: PayloadSize -> Int
payloadBytes = \case
  Small -> 100
  Medium -> 10_000
  Large -> 100_000

-- | Benchmark configuration loaded from environment variables
data BenchConfig = BenchConfig
  { -- | PostgreSQL connection string (required: PG_CONNECTION_STRING)
    connectionString :: !ByteString,
    -- | Number of messages for throughput tests (default: 1000)
    messageCount :: !Int,
    -- | Batch sizes to benchmark (default: [1,10,50,100])
    batchSizes :: ![Int],
    -- | Number of queues for multi-queue tests (default: 4)
    queueCount :: !Int,
    -- | Concurrent workers for concurrency tests (default: 4)
    concurrency :: !Int,
    -- | Payload size variants to test (default: [Small, Medium, Large])
    payloadSizes :: ![PayloadSize],
    -- | Skip queue cleanup after benchmarks (default: False)
    skipCleanup :: !Bool
  }
  deriving stock (Show, Eq, Generic)

-- | Load configuration from environment variables
loadConfig :: IO BenchConfig
loadConfig = do
  connStr <- getEnvRequired "PG_CONNECTION_STRING"
  msgCount <- getEnvIntDefault "BENCH_MESSAGE_COUNT" 1000
  batches <- getEnvBatchSizes "BENCH_BATCH_SIZES" [1, 10, 50, 100]
  queues <- getEnvIntDefault "BENCH_QUEUE_COUNT" 4
  workers <- getEnvIntDefault "BENCH_CONCURRENCY" 4
  payloads <- getEnvPayloadSizes "BENCH_PAYLOAD_SIZES" [Small, Medium, Large]
  cleanup <- getEnvBoolDefault "BENCH_SKIP_CLEANUP" False

  pure
    BenchConfig
      { connectionString = BS.pack connStr,
        messageCount = msgCount,
        batchSizes = batches,
        queueCount = queues,
        concurrency = workers,
        payloadSizes = payloads,
        skipCleanup = cleanup
      }

-- | Get a required environment variable or fail
getEnvRequired :: String -> IO String
getEnvRequired name = do
  mValue <- lookupEnv name
  case mValue of
    Nothing -> fail $ "Required environment variable not set: " <> name
    Just value
      | null value -> fail $ "Environment variable is empty: " <> name
      | otherwise -> pure value

-- | Get an integer environment variable with default
getEnvIntDefault :: String -> Int -> IO Int
getEnvIntDefault name def = do
  mValue <- lookupEnv name
  pure $ fromMaybe def (mValue >>= readMaybe)

-- | Get a boolean environment variable with default
getEnvBoolDefault :: String -> Bool -> IO Bool
getEnvBoolDefault name def = do
  mValue <- lookupEnv name
  pure $ case fmap (map toLower) mValue of
    Just "true" -> True
    Just "1" -> True
    Just "yes" -> True
    Just "false" -> False
    Just "0" -> False
    Just "no" -> False
    _ -> def

-- | Parse batch sizes from comma-separated string
getEnvBatchSizes :: String -> [Int] -> IO [Int]
getEnvBatchSizes name def = do
  mValue <- lookupEnv name
  pure $ case mValue of
    Nothing -> def
    Just s -> parseBatchSizes s

-- | Parse comma-separated batch sizes
parseBatchSizes :: String -> [Int]
parseBatchSizes s =
  let parts = splitOn ',' s
      parsed = [n | p <- parts, Just n <- [readMaybe p], n > 0]
   in if null parsed then [1, 10, 50, 100] else nub parsed

-- | Parse payload sizes from comma-separated string
getEnvPayloadSizes :: String -> [PayloadSize] -> IO [PayloadSize]
getEnvPayloadSizes name def = do
  mValue <- lookupEnv name
  pure $ case mValue of
    Nothing -> def
    Just s -> parsePayloadSizes s

-- | Parse comma-separated payload sizes
parsePayloadSizes :: String -> [PayloadSize]
parsePayloadSizes s =
  let parts = splitOn ',' s
      parsed = [p | part <- parts, Just p <- [parsePayloadSize (map toLower part)]]
   in if null parsed then [Small, Medium, Large] else nub parsed
  where
    parsePayloadSize "small" = Just Small
    parsePayloadSize "medium" = Just Medium
    parsePayloadSize "large" = Just Large
    parsePayloadSize _ = Nothing

-- | Split string on character
splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (x, []) -> [x]
  (x, _ : rest) -> x : splitOn c rest
