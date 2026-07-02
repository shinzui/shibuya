-- | AckHandle for mechanical acknowledgment.
-- This is the Broadway.Acknowledger equivalent, but typed.
--
-- The framework calls 'finalize' at most once per delivery with a resolved
-- decision, except when retrying the same decision after a transient finalizer
-- failure. Adapters must therefore make finalization idempotent or
-- phase-tracked: re-running a partially completed finalization with the same
-- decision must be safe. The framework never intentionally finalizes one
-- delivery with two different decisions.
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
  { -- | Finalize the message with the given decision.
    --
    -- This action may be retried with the same decision under the framework's
    -- bounded retry schedule when it throws.
    finalize :: AckDecision -> Eff es ()
  }
