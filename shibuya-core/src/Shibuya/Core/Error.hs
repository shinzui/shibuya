-- | Unified error types for Shibuya.
-- Provides structured errors with consistent representation across the library.
module Shibuya.Core.Error
  ( -- * Policy Errors
    PolicyError (..),
    policyErrorToText,

    -- * Handler Errors
    HandlerError (..),
    handlerErrorToText,

    -- * Runtime Errors
    RuntimeError (..),
    runtimeErrorToText,

    -- * Configuration Errors
    ConfigError (..),
    configErrorToText,
  )
where

import Data.Text qualified as Text
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Prelude

-- | Policy validation errors.
data PolicyError
  = -- | Invalid combination of ordering and concurrency
    InvalidPolicyCombo !Text
  | -- | Ahead and Async concurrency must be positive.
    InvalidConcurrency !Int
  | -- | A derived concurrency buffer would overflow 'Int'.
    ConcurrencyCapacityOverflow !Int
  deriving stock (Eq, Show, Generic)

-- | Convert policy error to text for display.
policyErrorToText :: PolicyError -> Text
policyErrorToText (InvalidPolicyCombo msg) = msg
policyErrorToText (InvalidConcurrency n) =
  "concurrency must be >= 1, got " <> Text.pack (show n)
policyErrorToText (ConcurrencyCapacityOverflow n) =
  "concurrency is too large to derive a bounded buffer safely, got " <> Text.pack (show n)

-- | Handler execution errors.
data HandlerError
  = -- | Handler threw an exception
    HandlerException !Text
  deriving stock (Eq, Show, Generic)

-- | Convert handler error to text for display.
handlerErrorToText :: HandlerError -> Text
handlerErrorToText (HandlerException msg) = msg

-- | Runtime errors during processing.
data RuntimeError
  = -- | Supervisor failed
    SupervisorFailed !Text
  deriving stock (Eq, Show, Generic)

-- | Convert runtime error to text for display.
runtimeErrorToText :: RuntimeError -> Text
runtimeErrorToText (SupervisorFailed msg) = msg

-- | Application configuration errors, detected before any processor starts.
data ConfigError
  = -- | inboxSize must be >= 1; 0 stalls ingestion, negatives are nonsense.
    InvalidInboxSize !Int
  | -- | Processor identifiers must be unique within one application.
    DuplicateProcessorId !ProcessorId
  deriving stock (Eq, Show, Generic)

-- | Convert configuration error to text for display.
configErrorToText :: ConfigError -> Text
configErrorToText (InvalidInboxSize n) =
  "inboxSize must be >= 1, got " <> Text.pack (show n)
configErrorToText (DuplicateProcessorId (ProcessorId pid)) =
  "processor IDs must be unique, duplicate: " <> pid
