-- | Health check types and logic for Kubernetes-compatible probes.
--
-- Provides:
-- * Liveness probe: Is the system running?
-- * Readiness probe: Is the system ready to handle traffic?
-- * Detailed health status for debugging
module Shibuya.Metrics.Health
  ( -- * Health Status Types
    LivenessStatus (..),
    ReadinessStatus (..),
    ProcessorHealth (..),
    DependencyStatus (..),

    -- * Health Check Configuration
    HealthConfig (..),
    defaultHealthConfig,

    -- * Health Check Functions
    checkLiveness,
    checkReadiness,
    checkDetailedHealth,

    -- * Dependency Checks
    DependencyCheck,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Shibuya.Runner.Master (Master, getAllMetricsIO)
import Shibuya.Runner.Metrics
  ( MetricsMap,
    ProcessorMetrics (..),
    ProcessorState (..),
  )
import System.Timeout (timeout)

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

-- | Configuration for health checks.
data HealthConfig = HealthConfig
  { -- | Timeout for liveness check (microseconds)
    livenessTimeoutMicros :: !Int,
    -- | How long a processor can be in Processing state before considered stuck
    stuckThreshold :: !NominalDiffTime
  }
  deriving stock (Eq, Show)

-- | Default health configuration.
-- Liveness timeout: 1 second
-- Stuck threshold: 60 seconds
defaultHealthConfig :: HealthConfig
defaultHealthConfig =
  HealthConfig
    { livenessTimeoutMicros = 1_000_000,
      stuckThreshold = 60
    }

--------------------------------------------------------------------------------
-- Health Status Types
--------------------------------------------------------------------------------

-- | Liveness status for Kubernetes liveness probe.
-- A simple "am I running?" check.
data LivenessStatus = LivenessStatus
  { alive :: !Bool
  }
  deriving stock (Eq, Show)

instance ToJSON LivenessStatus where
  toJSON status =
    object
      [ "alive" .= status.alive
      ]

-- | Readiness status for Kubernetes readiness probe.
-- Indicates whether the system is ready to handle traffic.
data ReadinessStatus = ReadinessStatus
  { ready :: !Bool,
    processors :: !ProcessorHealth,
    dependencies :: ![DependencyStatus]
  }
  deriving stock (Eq, Show)

instance ToJSON ReadinessStatus where
  toJSON status =
    object
      [ "ready" .= status.ready,
        "processors" .= status.processors,
        "dependencies" .= status.dependencies
      ]

-- | Summary of processor health across all processors.
data ProcessorHealth = ProcessorHealth
  { total :: !Int,
    healthy :: !Int,
    failed :: !Int,
    stuck :: !Int
  }
  deriving stock (Eq, Show)

instance ToJSON ProcessorHealth where
  toJSON ph =
    object
      [ "total" .= ph.total,
        "healthy" .= ph.healthy,
        "failed" .= ph.failed,
        "stuck" .= ph.stuck
      ]

-- | Status of an external dependency.
data DependencyStatus = DependencyStatus
  { name :: !Text,
    healthy :: !Bool,
    latencyMs :: !(Maybe Int),
    errorMsg :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON DependencyStatus where
  toJSON ds =
    object
      [ "name" .= ds.name,
        "healthy" .= ds.healthy,
        "latencyMs" .= ds.latencyMs,
        "error" .= ds.errorMsg
      ]

-- | A dependency check is an IO action that returns the dependency's status.
type DependencyCheck = IO DependencyStatus

--------------------------------------------------------------------------------
-- Health Check Functions
--------------------------------------------------------------------------------

-- | Check liveness - is the master responding?
-- This is a fast check suitable for Kubernetes liveness probes.
checkLiveness :: HealthConfig -> Master -> IO LivenessStatus
checkLiveness config master = do
  -- Try to query metrics with timeout
  result <- timeout config.livenessTimeoutMicros $ getAllMetricsIO master
  pure $ LivenessStatus {alive = isJust result}

-- | Check readiness - are all processors healthy and dependencies available?
-- This is suitable for Kubernetes readiness probes.
checkReadiness ::
  HealthConfig ->
  Master ->
  [DependencyCheck] ->
  IO ReadinessStatus
checkReadiness config master depChecks = do
  now <- getCurrentTime
  metrics <- getAllMetricsIO master
  let procHealth = analyzeProcessorHealth config now metrics
  depStatus <- sequence depChecks

  let allDepsHealthy = all (.healthy) depStatus
      noFailedProcessors = procHealth.failed == 0
      noStuckProcessors = procHealth.stuck == 0
      isReady = allDepsHealthy && noFailedProcessors && noStuckProcessors

  pure
    ReadinessStatus
      { ready = isReady,
        processors = procHealth,
        dependencies = depStatus
      }

-- | Get detailed health status for debugging.
-- Returns the full metrics along with health analysis.
checkDetailedHealth ::
  HealthConfig ->
  Master ->
  [DependencyCheck] ->
  IO (ReadinessStatus, MetricsMap)
checkDetailedHealth config master depChecks = do
  readiness <- checkReadiness config master depChecks
  metrics <- getAllMetricsIO master
  pure (readiness, metrics)

--------------------------------------------------------------------------------
-- Internal Helpers
--------------------------------------------------------------------------------

-- | Analyze processor health from metrics.
analyzeProcessorHealth :: HealthConfig -> UTCTime -> MetricsMap -> ProcessorHealth
analyzeProcessorHealth config now metrics =
  let processors = Map.elems metrics
      total = length processors
      (healthy, failed, stuck) = foldr (categorize config now) (0, 0, 0) processors
   in ProcessorHealth
        { total = total,
          healthy = healthy,
          failed = failed,
          stuck = stuck
        }

-- | Categorize a processor as healthy, failed, or stuck.
categorize ::
  HealthConfig ->
  UTCTime ->
  ProcessorMetrics ->
  (Int, Int, Int) ->
  (Int, Int, Int)
categorize config now pm (h, f, s) =
  case pm.state of
    Idle -> (h + 1, f, s)
    Stopped -> (h, f, s) -- Stopped is neither healthy nor failed
    Failed _ _ -> (h, f + 1, s)
    Processing _ lastActivity ->
      let timeSinceActivity = diffUTCTime now lastActivity
       in if timeSinceActivity > config.stuckThreshold
            then (h, f, s + 1) -- Stuck
            else (h + 1, f, s) -- Healthy (actively processing)
