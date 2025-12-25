-- | Shibuya Core - Public API
--
-- This module re-exports all public types and functions from the Shibuya framework.
-- Import this module for application development.
module Shibuya.Core
  ( -- * Message Types
    MessageId (..),
    Cursor (..),
    Envelope (..),

    -- * Ack Semantics
    AckDecision (..),
    RetryDelay (..),
    DeadLetterReason (..),
    HaltReason (..),

    -- * Handler Types
    AckHandle (..),
    Lease (..),
    Ingested (..),

    -- * Handler
    Handler,

    -- * Adapter
    Adapter (..),

    -- * Policy
    Ordering (..),
    Concurrency (..),
    validatePolicy,

    -- * Runner
    RunnerConfig (..),
    defaultRunnerConfig,

    -- * App
    runApp,
    AppError (..),

    -- * Master & Supervision
    Master (..),
    startMaster,
    stopMaster,
    getAllMetrics,
    getProcessorMetrics,
    Strategy (..),

    -- * Supervised Processors
    SupervisedProcessor (..),
    runSupervised,
    runWithMetrics,
    getMetrics,
    getProcessorState,
    isDone,

    -- * Metrics
    ProcessorId (..),
    ProcessorState (..),
    ProcessorMetrics (..),
    StreamStats (..),
    MetricsMap,
  )
where

import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppError (..), runApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Lease (Lease (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), Ordering (..), validatePolicy)
import Shibuya.Runner (RunnerConfig (..), defaultRunnerConfig)
import Shibuya.Runner.Master (Master (..), getAllMetrics, getProcessorMetrics, startMaster, stopMaster)
import Shibuya.Runner.Metrics (MetricsMap, ProcessorId (..), ProcessorMetrics (..), ProcessorState (..), StreamStats (..))
import Shibuya.Runner.Supervised (SupervisedProcessor (..), getMetrics, getProcessorState, isDone, runSupervised, runWithMetrics)
import Prelude hiding (Ordering)
