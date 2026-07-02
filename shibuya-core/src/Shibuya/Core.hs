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
    Attempt (..),
    Envelope (..),
    Headers,

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

    -- * App
    runApp,
    AppError (..),
    QueueProcessor (..),
    mkProcessor,
    AppHandle,
    waitApp,
    stopApp,
    stopAppGracefully,
    getAppMetrics,

    -- * Shutdown Configuration
    ShutdownConfig (..),
    defaultShutdownConfig,

    -- * Supervision Strategy
    SupervisionStrategy (..),

    -- * Errors
    PolicyError (..),
    HandlerError (..),
    RuntimeError (..),

    -- * Metrics
    ProcessorId (..),
    ProcessorState (..),
    ProcessorMetrics (..),
    StreamStats (..),
    InFlightInfo (..),
    MetricsMap,

    -- * Halt
    ProcessorHalt (..),
  )
where

import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppError (..), AppHandle, QueueProcessor (..), ShutdownConfig (..), SupervisionStrategy (..), defaultShutdownConfig, getAppMetrics, mkProcessor, runApp, stopApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), HaltReason (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Error (HandlerError (..), PolicyError (..), RuntimeError (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Lease (Lease (..))
import Shibuya.Core.Metrics (InFlightInfo (..), MetricsMap, ProcessorId (..), ProcessorMetrics (..), ProcessorState (..), StreamStats (..))
import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), Headers, MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Internal.Runner.Halt (ProcessorHalt (..))
import Shibuya.Policy (Concurrency (..), Ordering (..), validatePolicy)
import Prelude hiding (Ordering)
