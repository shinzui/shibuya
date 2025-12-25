-- | AckHandle for mechanical acknowledgment.
-- This is the Broadway.Acknowledger equivalent, but typed.
-- Must be called exactly once; adapter enforces idempotency.
module Shibuya.Core.AckHandle
  ( AckHandle (..),
  )
where

import Effectful (Eff)
import Shibuya.Core.Ack (AckDecision)

-- | Mechanical ack interface (adapter-provided).
-- The handler's AckDecision is passed to finalize, which performs
-- the actual commit/retry/dead-letter operation.
newtype AckHandle es = AckHandle
  { -- | Finalize the message with the given decision
    finalize :: AckDecision -> Eff es ()
  }
