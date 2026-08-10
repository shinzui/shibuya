-- | Ack semantics for message processing.
-- Handlers decide meaning, not mechanics.
-- This is explicit to support halt-on-error for ordered streams.
module Shibuya.Core.Ack
  ( -- * Retry
    RetryDelay (..),

    -- * Dead Letter
    DeadLetterCode,
    mkDeadLetterCode,
    deadLetterCodeText,
    DeadLetterReason (..),
    deadLetterReasonCode,
    deadLetterReasonDetail,
    renderDeadLetterReason,

    -- * Halt
    HaltReason (..),

    -- * Handler Decision
    AckDecision (..),
  )
where

import Data.Char (isAsciiLower)
import Data.Text qualified as Text
import Shibuya.Prelude

-- | Delay before retry.
newtype RetryDelay = RetryDelay {unRetryDelay :: NominalDiffTime}
  deriving stock (Eq, Show)

-- | A stable, machine-queryable application dead-letter identifier.
--
-- The constructor is intentionally private. Validate a finite set of codes
-- during application startup, retain the resulting values in configuration,
-- and reuse them in handlers rather than validating on every message.
newtype DeadLetterCode = DeadLetterCode Text
  deriving stock (Eq, Ord, Show)

-- | Validate an application-owned dead-letter code.
--
-- A valid code is at most 128 ASCII characters and contains at least two
-- dot-separated segments. Each segment starts with a lowercase ASCII letter
-- and then contains only lowercase ASCII letters, digits, or underscores. The
-- first segment @shibuya@ is reserved for framework-owned codes.
mkDeadLetterCode :: Text -> Either Text DeadLetterCode
mkDeadLetterCode code
  | Text.null code = invalid "must not be empty"
  | Text.length (Text.take 129 code) > 128 = invalid "must contain at most 128 ASCII characters"
  | length segments < 2 = invalid "must contain at least two dot-separated segments"
  | Just segment <- firstInvalidSegment segments =
      invalid $ Text.concat ["segment \"", segment, "\" must match [a-z][a-z0-9_]*"]
  | hasReservedFirstSegment segments = invalid "must not use the reserved first segment \"shibuya\""
  | otherwise = Right (DeadLetterCode code)
  where
    segments = Text.splitOn "." code
    invalid rule = Left $ Text.concat ["invalid dead-letter code \"", code, "\": ", rule]

-- | Unwrap a validated dead-letter code for storage, tracing, or logging.
deadLetterCodeText :: DeadLetterCode -> Text
deadLetterCodeText (DeadLetterCode code) = code

-- | Why a message is being dead-lettered.
data DeadLetterReason
  = -- | The message is permanently unprocessable, despite retries.
    PoisonPill !Text
  | -- | The message payload failed parsing or structural validation.
    InvalidPayload !Text
  | -- | The framework's retry limit was exceeded.
    MaxRetriesExceeded
  | -- | A syntactically valid message was permanently rejected by
    -- application policy.
    --
    -- The application owns the stability of the code. Detail is transported
    -- verbatim for operators and must not contain secrets, unrestricted
    -- backend errors, raw SQL, or full payloads.
    ApplicationFailure !DeadLetterCode !Text
  deriving stock (Eq, Show, Generic)

-- | Return the stable machine-facing code for any dead-letter reason.
deadLetterReasonCode :: DeadLetterReason -> DeadLetterCode
deadLetterReasonCode (PoisonPill _) = poisonPillCode
deadLetterReasonCode (InvalidPayload _) = invalidPayloadCode
deadLetterReasonCode MaxRetriesExceeded = maxRetriesExceededCode
deadLetterReasonCode (ApplicationFailure code _) = code

-- | Return human-facing detail when the reason carries it.
--
-- Detail is transported verbatim. Applications must keep it operationally
-- bounded and exclude secrets, raw payloads, raw SQL, and unrestricted
-- backend error text.
deadLetterReasonDetail :: DeadLetterReason -> Maybe Text
deadLetterReasonDetail (PoisonPill detail) = Just detail
deadLetterReasonDetail (InvalidPayload detail) = Just detail
deadLetterReasonDetail MaxRetriesExceeded = Nothing
deadLetterReasonDetail (ApplicationFailure _ detail) = Just detail

-- | Render a reason in Shibuya's canonical compatibility format.
--
-- Built-in strings retain their historical encoding. Adapters with
-- structured storage should prefer 'deadLetterReasonCode' and
-- 'deadLetterReasonDetail' separately.
renderDeadLetterReason :: DeadLetterReason -> Text
renderDeadLetterReason reason =
  let code = deadLetterCodeText (deadLetterReasonCode reason)
   in case deadLetterReasonDetail reason of
        Nothing -> code
        Just detail -> Text.concat [code, ": ", detail]

firstInvalidSegment :: [Text] -> Maybe Text
firstInvalidSegment [] = Nothing
firstInvalidSegment (segment : rest)
  | validSegment segment = firstInvalidSegment rest
  | otherwise = Just segment

validSegment :: Text -> Bool
validSegment segment =
  case Text.uncons segment of
    Nothing -> False
    Just (first, suffix) ->
      isAsciiLower first && Text.all validSegmentSuffix suffix

validSegmentSuffix :: Char -> Bool
validSegmentSuffix char =
  isAsciiLower char || ('0' <= char && char <= '9') || char == '_'

hasReservedFirstSegment :: [Text] -> Bool
hasReservedFirstSegment (first : _) = first == "shibuya"
hasReservedFirstSegment [] = False

poisonPillCode :: DeadLetterCode
poisonPillCode = DeadLetterCode "poison_pill"

invalidPayloadCode :: DeadLetterCode
invalidPayloadCode = DeadLetterCode "invalid_payload"

maxRetriesExceededCode :: DeadLetterCode
maxRetriesExceededCode = DeadLetterCode "max_retries_exceeded"

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
