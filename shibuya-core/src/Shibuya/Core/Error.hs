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
  )
where

import Shibuya.Prelude

-- | Policy validation errors.
data PolicyError
  = -- | Invalid combination of ordering and concurrency
    InvalidPolicyCombo !Text
  deriving stock (Eq, Show, Generic)

-- | Convert policy error to text for display.
policyErrorToText :: PolicyError -> Text
policyErrorToText (InvalidPolicyCombo msg) = msg

-- | Handler execution errors.
data HandlerError
  = -- | Handler threw an exception
    HandlerException !Text
  | -- | Handler timed out
    HandlerTimeout
  deriving stock (Eq, Show, Generic)

-- | Convert handler error to text for display.
handlerErrorToText :: HandlerError -> Text
handlerErrorToText (HandlerException msg) = msg
handlerErrorToText HandlerTimeout = "Handler timed out"

-- | Runtime errors during processing.
data RuntimeError
  = -- | Supervisor failed
    SupervisorFailed !Text
  | -- | Inbox overflow (backpressure failure)
    InboxOverflow
  deriving stock (Eq, Show, Generic)

-- | Convert runtime error to text for display.
runtimeErrorToText :: RuntimeError -> Text
runtimeErrorToText (SupervisorFailed msg) = msg
runtimeErrorToText InboxOverflow = "Inbox overflow"
