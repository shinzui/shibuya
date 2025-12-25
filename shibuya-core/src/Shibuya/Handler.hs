-- | Handler API - this is all application authors need to know.
-- Handlers cannot ack directly, cannot influence concurrency,
-- and express intent only via AckDecision.
module Shibuya.Handler
  ( Handler,
  )
where

import Effectful (Eff)
import Shibuya.Core.Ack (AckDecision)
import Shibuya.Core.Ingested (Ingested)

-- | Handler function type.
-- Takes an ingested message and returns an ack decision.
type Handler es msg = Ingested es msg -> Eff es AckDecision
