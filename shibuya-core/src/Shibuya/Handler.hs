-- | Handler API - this is all application authors need to know.
-- Handlers cannot ack directly, cannot influence concurrency,
-- and express intent only via AckDecision.
module Shibuya.Handler
  ( Handler,
  )
where

import Effectful (Eff)
import Shibuya.Core.Ack (AckDecision)
import Shibuya.Core.Ingested (Message)

-- | Handler function type.
-- Takes a read-only message view and returns an ack decision.
--
-- If a handler throws, the framework records the failure and finalizes the
-- message with @AckRetry (RetryDelay 0)@ so the message is not lost. A handler
-- that needs a different disposition should catch its own exception and return
-- the desired 'AckDecision'.
type Handler es msg = Message es msg -> Eff es AckDecision
