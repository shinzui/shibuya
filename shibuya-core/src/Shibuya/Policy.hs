-- | Ordering and concurrency policies.
-- Runner policy that maps ordering guarantees to concurrency constraints.
module Shibuya.Policy
  ( -- * Ordering
    Ordering (..),

    -- * Concurrency
    Concurrency (..),

    -- * Validation
    validatePolicy,
  )
where

import Shibuya.Prelude
import Prelude hiding (Ordering)

-- | Message ordering guarantees.
data Ordering
  = -- | Event-sourced subscriptions - must be Serial
    StrictInOrder
  | -- | Kafka-style - parallel across partitions
    PartitionedInOrder
  | -- | No ordering guarantees
    Unordered
  deriving stock (Eq, Show, Generic)

-- | Concurrency mode.
data Concurrency
  = -- | One message at a time
    Serial
  | -- | Prefetch N, process in order
    Ahead !Int
  | -- | Process N concurrently
    Async !Int
  deriving stock (Eq, Show, Generic)

-- | Validate policy combinations.
-- Invariant: StrictInOrder => Serial
validatePolicy :: Ordering -> Concurrency -> Either Text ()
validatePolicy StrictInOrder (Ahead _) = Left "StrictInOrder requires Serial concurrency"
validatePolicy StrictInOrder (Async _) = Left "StrictInOrder requires Serial concurrency"
validatePolicy _ _ = Right ()
