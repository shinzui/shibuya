-- | Ack semantics for message processing.
-- Handlers decide meaning, not mechanics.
-- This is explicit to support halt-on-error for ordered streams.
module Shibuya.Core.Ack
  ( -- * Retry
    RetryDelay (..),

    -- * Dead Letter
    DeadLetterReason (..),

    -- * Halt
    HaltReason (..),

    -- * Handler Decision
    AckDecision (..),
  )
where

import Shibuya.Prelude

-- | Delay before retry.
newtype RetryDelay = RetryDelay {unRetryDelay :: NominalDiffTime}
  deriving stock (Eq, Show)

-- | Why a message is being dead-lettered.
data DeadLetterReason
  = -- | Message is permanently unprocessable
    PoisonPill !Text
  | -- | Message payload failed validation/parsing
    InvalidPayload !Text
  | -- | Retry limit exceeded
    MaxRetriesExceeded
  deriving stock (Eq, Show, Generic)

-- | Why processing should halt.
data HaltReason
  = -- | Must stop to preserve ordering guarantees
    HaltOrderedStream !Text
  | -- | Unrecoverable error
    HaltFatal !Text
  deriving stock (Eq, Show, Generic)

-- | Handler outcome (semantic, not mechanical).
-- The handler returns this to express intent; the framework handles the mechanics.
data AckDecision
  = -- | Message processed successfully
    AckOk
  | -- | Retry after delay
    AckRetry !RetryDelay
  | -- | Move to dead letter queue
    AckDeadLetter !DeadLetterReason
  | -- | Stop processing
    AckHalt !HaltReason
  deriving stock (Eq, Show, Generic)
