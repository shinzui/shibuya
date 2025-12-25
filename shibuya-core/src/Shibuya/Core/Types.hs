-- | Core types for the Shibuya framework.
-- These types exist everywhere and should be extremely stable.
-- No behavior, no effects, no policy - just identity + payload + metadata.
module Shibuya.Core.Types
  ( -- * Message Identity
    MessageId (..),

    -- * Cursor / Offset
    Cursor (..),

    -- * Message Envelope
    Envelope (..),
  )
where

import Data.String (IsString)
import Shibuya.Prelude

-- | Stable identity for idempotency & observability.
-- Every message has a unique identifier.
newtype MessageId = MessageId {unMessageId :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (IsString)

-- | Optional cursor / offset / global position.
-- Used to track position in ordered streams.
data Cursor
  = CursorInt !Int
  | CursorText !Text
  deriving stock (Eq, Ord, Show, Generic)

-- | Normalized message envelope (Broadway.Message equivalent).
-- Contains message metadata plus the payload.
data Envelope msg = Envelope
  { -- | Unique message identifier
    messageId :: !MessageId,
    -- | Optional position/offset
    cursor :: !(Maybe Cursor),
    -- | Optional partition key (for Kafka-style queues)
    partition :: !(Maybe Text),
    -- | When the message was enqueued
    enqueuedAt :: !(Maybe UTCTime),
    -- | The actual message payload
    payload :: !msg
  }
  deriving stock (Eq, Show, Functor, Generic)
