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

import Shibuya.Core.Error (PolicyError (..))
import Shibuya.Prelude
import Prelude hiding (Ordering)

-- | Message ordering guarantees.
data Ordering
  = -- | Event-sourced subscriptions - must be Serial
    StrictInOrder
  | -- | Kafka-style ordering: messages with the same partition key are
    -- processed and acknowledged in arrival order, while distinct partitions
    -- may run concurrently. Messages without a partition key are unconstrained.
    PartitionedInOrder
  | -- | No ordering guarantees
    Unordered
  deriving stock (Eq, Show, Generic)

-- | Concurrency mode.
data Concurrency
  = -- | One message at a time
    Serial
  | -- | Process up to N messages concurrently. Stream results are yielded
    -- downstream in input order, but handler execution and acknowledgement run
    -- concurrently and may complete in any order. Since Shibuya discards the
    -- per-message result, this ordered yielding is not observable as ordered
    -- side effects or ordered acks.
    Ahead !Int
  | -- | Process N concurrently
    Async !Int
  deriving stock (Eq, Show, Generic)

-- | Validate policy combinations.
-- Invariant: StrictInOrder => Serial
validatePolicy :: Ordering -> Concurrency -> Either PolicyError ()
validatePolicy StrictInOrder (Ahead _) = Left $ InvalidPolicyCombo "StrictInOrder requires Serial concurrency"
validatePolicy StrictInOrder (Async _) = Left $ InvalidPolicyCombo "StrictInOrder requires Serial concurrency"
validatePolicy _ _ = Right ()
