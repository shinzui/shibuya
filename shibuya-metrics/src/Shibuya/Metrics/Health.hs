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
    ApplicationStatus (..),
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
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Shibuya.App (Master, getAllMetricsIO)
import Shibuya.Core.Metrics
  ( MetricsMap,
    ProcessorId,
    ProcessorMetrics (..),
    ProcessorState (..),
  )
import Shibuya.Internal.Runner.Master
  ( LifecycleSnapshot,
    MasterPhase (..),
    ProcessorLifecycle (..),
    getLifecycleSnapshotIO,
    getMasterPhaseIO,
  )
import System.Timeout (timeout)

--------------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------------

-- | Configuration for health checks.
data HealthConfig = HealthConfig
  { -- | Timeout for liveness check (microseconds)
    livenessTimeoutMicros :: !Int,
    -- | Timeout for each dependency check (microseconds)
    dependencyTimeoutMicros :: !Int,
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
      dependencyTimeoutMicros = 1_000_000,
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
    application :: !ApplicationStatus,
    processors :: !ProcessorHealth,
    dependencies :: ![DependencyStatus]
  }
  deriving stock (Eq, Show)

instance ToJSON ReadinessStatus where
  toJSON status =
    object
      [ "ready" .= status.ready,
        "application" .= status.application,
        "processors" .= status.processors,
        "dependencies" .= status.dependencies
      ]

-- | Health-level application lifecycle derived from the master phase and the
-- retained configured-processor lifecycle snapshot.
data ApplicationStatus
  = ConfiguredEmpty
  | Starting
  | Running
  | Draining
  | ApplicationStopped
  | ApplicationFailed
  deriving stock (Eq, Show)

instance ToJSON ApplicationStatus where
  toJSON = \case
    ConfiguredEmpty -> toJSON ("configured_empty" :: Text)
    Starting -> toJSON ("starting" :: Text)
    Running -> toJSON ("running" :: Text)
    Draining -> toJSON ("draining" :: Text)
    ApplicationStopped -> toJSON ("stopped" :: Text)
    ApplicationFailed -> toJSON ("failed" :: Text)

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
  result <- timeout config.livenessTimeoutMicros $ getMasterPhaseIO master
  pure $
    LivenessStatus
      { alive = case result of
          Just MasterStopped -> False
          Just _ -> True
          Nothing -> False
      }

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
  lifecycles <- getLifecycleSnapshotIO master
  masterPhase <- getMasterPhaseIO master
  let procHealth = analyzeProcessorHealth config now metrics lifecycles
      application = classifyApplication masterPhase lifecycles
      allRunningVisible =
        all
          (\(pid, lifecycle) -> lifecycle /= LifecycleRunning || Map.member pid metrics)
          (Map.toList lifecycles)
  depStatus <- traverse (runDependencyCheck config) depChecks

  let allDepsHealthy = all (.healthy) depStatus
      noFailedProcessors = procHealth.failed == 0
      noStuckProcessors = procHealth.stuck == 0
      acceptsWork = application == Running || application == ConfiguredEmpty
      isReady = acceptsWork && allRunningVisible && allDepsHealthy && noFailedProcessors && noStuckProcessors

  pure
    ReadinessStatus
      { ready = isReady,
        application,
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
analyzeProcessorHealth :: HealthConfig -> UTCTime -> MetricsMap -> LifecycleSnapshot -> ProcessorHealth
analyzeProcessorHealth config now metrics lifecycles =
  let processorIds = Map.keysSet metrics <> Map.keysSet lifecycles
      total = length processorIds
      (healthy, failed, stuck) =
        foldr
          (categorize config now metrics lifecycles)
          (0, 0, 0)
          processorIds
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
  MetricsMap ->
  LifecycleSnapshot ->
  ProcessorId ->
  (Int, Int, Int) ->
  (Int, Int, Int)
categorize config now metrics lifecycles pid counts@(h, f, s) =
  case Map.lookup pid lifecycles of
    Just LifecycleFailed {} -> (h, f + 1, s)
    _ -> case Map.lookup pid metrics of
      Nothing -> counts
      Just pm -> case pm.state of
        Idle -> (h + 1, f, s)
        Stopped -> counts
        Failed _ _ -> (h, f + 1, s)
        Processing _ _ lastProgress ->
          let timeSinceProgress = diffUTCTime now lastProgress
           in if timeSinceProgress > config.stuckThreshold
                then (h, f, s + 1)
                else (h + 1, f, s)

classifyApplication :: MasterPhase -> LifecycleSnapshot -> ApplicationStatus
classifyApplication masterPhase lifecycles
  | any isFailed (Map.elems lifecycles) = ApplicationFailed
  | masterPhase == MasterStopped = ApplicationStopped
  | masterPhase == MasterDraining || any (== LifecycleDraining) (Map.elems lifecycles) = Draining
  | masterPhase == MasterStarting = Starting
  | Map.null lifecycles = ConfiguredEmpty
  | all (== LifecycleStopped) (Map.elems lifecycles) = ApplicationStopped
  | otherwise = Running
  where
    isFailed LifecycleFailed {} = True
    isFailed _ = False

runDependencyCheck :: HealthConfig -> DependencyCheck -> IO DependencyStatus
runDependencyCheck config check = do
  result <- timeout config.dependencyTimeoutMicros check
  pure $ case result of
    Just status -> status
    Nothing ->
      DependencyStatus
        { name = "unknown",
          healthy = False,
          latencyMs = Nothing,
          errorMsg =
            Just $
              "Dependency check timed out after "
                <> Text.pack (show config.dependencyTimeoutMicros)
                <> " microseconds"
        }
