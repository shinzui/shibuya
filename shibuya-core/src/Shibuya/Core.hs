-- | Shibuya Core - Public API
--
-- This module re-exports all public types and functions from the Shibuya framework.
-- Import this module for application development.
--
-- Example:
--
-- @
-- import Shibuya.Core
--
-- main = runEff $ do
--   let processor = QueueProcessor myAdapter myHandler
--   result <- runApp IgnoreFailures 100 [(ProcessorId "main", processor)]
--   case result of
--     Right handle -> waitApp handle
--     Left err -> print err
-- @
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
    QueueProcessor (..),
    AppHandle (..),
    waitApp,
    stopApp,
    getAppMetrics,

    -- * Supervision Strategy
    SupervisionStrategy (..),

    -- * Metrics
    ProcessorId (..),
    ProcessorState (..),
    ProcessorMetrics (..),
    StreamStats (..),
    MetricsMap,

    -- * Halt
    ProcessorHalt (..),
  )
where

import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppError (..), AppHandle (..), QueueProcessor (..), SupervisionStrategy (..), getAppMetrics, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Lease (Lease (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), Ordering (..), validatePolicy)
import Shibuya.Runner (RunnerConfig (..), defaultRunnerConfig)
import Shibuya.Runner.Halt (ProcessorHalt (..))
import Shibuya.Runner.Metrics (MetricsMap, ProcessorId (..), ProcessorMetrics (..), ProcessorState (..), StreamStats (..))
import Prelude hiding (Ordering)
