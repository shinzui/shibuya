-- | The Shibuya framework: supervised queue processing with explicit acks.
-- This is the single import an application author needs.
module Shibuya
  ( -- * Running an application
    runApp,
    AppConfig (..),
    defaultAppConfig,
    AppError (..),
    QueueProcessor (..),
    mkProcessor,
    mkBatchProcessor,
    AppHandle,
    getAppMetrics,
    getAppMaster,
    waitApp,
    stopApp,
    stopAppGracefully,
    ShutdownConfig (..),
    defaultShutdownConfig,
    SupervisionStrategy (..),

    -- * Messages and envelopes
    MessageId (..),
    Cursor (..),
    Attempt (..),
    Envelope (..),
    mkEnvelope,
    Headers,
    TraceHeaders,
    Message (..),

    -- * Handlers and acks
    Handler,
    AckDecision (..),
    RetryDelay (..),
    DeadLetterCode,
    mkDeadLetterCode,
    deadLetterCodeText,
    DeadLetterReason (..),
    deadLetterReasonCode,
    deadLetterReasonDetail,
    renderDeadLetterReason,
    HaltReason (..),
    ProcessorHalt (..),

    -- * Batch processing
    BatchHandler,
    BatchConfig (..),
    defaultBatchConfig,
    BatchKey (..),
    defaultBatchKey,
    BatchInfo (..),
    BatchTrigger (..),
    BatchAck (..),
    ackAllOk,
    ackAll,
    ackExcept,
    withFallback,
    failMessages,
    BatchConfigError (..),
    validateBatchConfig,

    -- * Retry helpers
    module Shibuya.Core.Retry,

    -- * Policies
    OrderingPolicy (..),
    Concurrency (..),
    validatePolicy,

    -- * Adapter authoring
    Adapter (..),
    AckHandle (..),
    Lease (..),
    Ingested (..),
    mkIngested,
    toMessage,

    -- * Errors
    PolicyError (..),
    HandlerError (..),
    RuntimeError (..),
    ConfigError (..),

    -- * Metrics and introspection
    Master,
    ProcessorId (..),
    ProcessorState (..),
    ProcessorMetrics (..),
    StreamStats (..),
    BatchStats (..),
    InFlightInfo (..),
    MetricsMap,

    -- * Tracing
    Tracing,
    runTracing,
    runTracingNoop,
  )
where

import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( AppConfig (..),
    AppError (..),
    AppHandle,
    Master,
    QueueProcessor (..),
    ShutdownConfig (..),
    SupervisionStrategy (..),
    defaultAppConfig,
    defaultShutdownConfig,
    getAppMaster,
    getAppMetrics,
    mkBatchProcessor,
    mkProcessor,
    runApp,
    stopApp,
    stopAppGracefully,
    waitApp,
  )
import Shibuya.Batch
import Shibuya.Core.Ack
  ( AckDecision (..),
    DeadLetterCode,
    DeadLetterReason (..),
    HaltReason (..),
    RetryDelay (..),
    deadLetterCodeText,
    deadLetterReasonCode,
    deadLetterReasonDetail,
    mkDeadLetterCode,
    renderDeadLetterReason,
  )
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Error (ConfigError (..), HandlerError (..), PolicyError (..), RuntimeError (..))
import Shibuya.Core.Ingested (Ingested (..), Message (..), mkIngested, toMessage)
import Shibuya.Core.Lease (Lease (..))
import Shibuya.Core.Metrics
  ( BatchStats (..),
    InFlightInfo (..),
    MetricsMap,
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
  )
import Shibuya.Core.Retry
import Shibuya.Core.Types (Attempt (..), Cursor (..), Envelope (..), Headers, MessageId (..), TraceHeaders, mkEnvelope)
import Shibuya.Handler (Handler)
import Shibuya.Internal.Runner.Halt (ProcessorHalt (..))
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..), validatePolicy)
import Shibuya.Telemetry.Effect (Tracing, runTracing, runTracingNoop)
