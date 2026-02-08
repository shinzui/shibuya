-- | Configuration parsing for the PGMQ example application.
--
-- Reads configuration from environment variables:
--
-- @
-- DATABASE_URL          - PostgreSQL connection string (required)
-- OTEL_TRACING_ENABLED  - Enable OpenTelemetry tracing (default: false)
-- OTEL_SERVICE_NAME     - Service name for tracing (default: shibuya-pgmq-example)
-- METRICS_PORT          - HTTP port for metrics server (default: 9090)
-- @
module Example.Config
  ( -- * Configuration Types
    AppConfig (..),
    SimulatorConfig (..),
    QueueTarget (..),

    -- * Loading Configuration
    loadAppConfig,
    loadSimulatorConfig,
    parseQueueTarget,

    -- * Helpers
    getEnvDefault,
    getEnvBool,
    getEnvInt,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS
import Data.Text (Text)
import Data.Text qualified as Text
import System.Environment (getEnv, lookupEnv)
import Text.Read (readMaybe)

-- | Application configuration for the consumer.
data AppConfig = AppConfig
  { connectionString :: !ByteString,
    tracingEnabled :: !Bool,
    serviceName :: !Text,
    metricsPort :: !Int
  }
  deriving stock (Show)

-- | Configuration for the simulator.
data SimulatorConfig = SimulatorConfig
  { connectionString :: !ByteString,
    queueTarget :: !QueueTarget,
    messageCount :: !Int,
    messagesPerSecond :: !Int,
    batchSize :: !Int
  }
  deriving stock (Show)

-- | Target queue for the simulator.
data QueueTarget
  = OrdersQueue
  | PaymentsQueue
  | NotificationsQueue
  deriving stock (Show, Eq)

-- | Parse queue target from string.
parseQueueTarget :: String -> Maybe QueueTarget
parseQueueTarget s = case map toLower s of
  "orders" -> Just OrdersQueue
  "payments" -> Just PaymentsQueue
  "notifications" -> Just NotificationsQueue
  _ -> Nothing
  where
    toLower c
      | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
      | otherwise = c

-- | Load application configuration from environment.
loadAppConfig :: IO AppConfig
loadAppConfig = do
  connStr <- getEnv "DATABASE_URL"
  tracing <- getEnvBool "OTEL_TRACING_ENABLED" False
  svcName <- getEnvDefault "OTEL_SERVICE_NAME" "shibuya-pgmq-example"
  port <- getEnvInt "METRICS_PORT" 9090
  pure
    AppConfig
      { connectionString = BS.pack connStr,
        tracingEnabled = tracing,
        serviceName = Text.pack svcName,
        metricsPort = port
      }

-- | Load simulator configuration from environment and arguments.
loadSimulatorConfig :: QueueTarget -> Int -> Int -> Int -> IO SimulatorConfig
loadSimulatorConfig target count rate batch = do
  connStr <- getEnv "DATABASE_URL"
  pure
    SimulatorConfig
      { connectionString = BS.pack connStr,
        queueTarget = target,
        messageCount = count,
        messagesPerSecond = rate,
        batchSize = batch
      }

-- | Get environment variable with default.
getEnvDefault :: String -> String -> IO String
getEnvDefault name def = do
  mVal <- lookupEnv name
  pure $ maybe def id mVal

-- | Get boolean environment variable.
getEnvBool :: String -> Bool -> IO Bool
getEnvBool name def = do
  mVal <- lookupEnv name
  pure $ case mVal of
    Just "true" -> True
    Just "1" -> True
    Just "yes" -> True
    Just "false" -> False
    Just "0" -> False
    Just "no" -> False
    _ -> def

-- | Get integer environment variable.
getEnvInt :: String -> Int -> IO Int
getEnvInt name def = do
  mVal <- lookupEnv name
  pure $ maybe def id (mVal >>= readMaybe)
