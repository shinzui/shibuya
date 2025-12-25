-- | Ingested message type - what handlers receive.
-- Combines Broadway.Message + Acknowledger + optional lease.
-- Exactly one thing flows through the system.
module Shibuya.Core.Ingested
  ( Ingested (..),
  )
where

import Shibuya.Core.AckHandle (AckHandle)
import Shibuya.Core.Lease (Lease)
import Shibuya.Core.Types (Envelope)

-- | What handlers receive for processing.
-- Contains the message envelope, ack handle, and optional lease.
data Ingested es msg = Ingested
  { -- | Message metadata and payload
    envelope :: !(Envelope msg),
    -- | Handle for acknowledging the message
    ack :: !(AckHandle es),
    -- | Optional lease for visibility timeout extension
    lease :: !(Maybe (Lease es))
  }
