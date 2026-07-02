-- | Ingested message type - what handlers receive.
-- Combines Broadway.Message + Acknowledger + optional lease.
-- Exactly one thing flows through the system.
module Shibuya.Core.Ingested
  ( Ingested (..),
    Message (..),
    toMessage,
    mkIngested,
  )
where

import Shibuya.Core.AckHandle (AckHandle)
import Shibuya.Core.Lease (Lease)
import Shibuya.Core.Types (Envelope)

-- | Framework-side message with the adapter-provided ack finalizer.
-- Adapters construct this; application handlers receive 'Message' instead.
data Ingested es msg = Ingested
  { -- | Message metadata and payload
    envelope :: !(Envelope msg),
    -- | Handle for acknowledging the message
    ack :: !(AckHandle es),
    -- | Optional lease for visibility timeout extension
    lease :: !(Maybe (Lease es))
  }

-- | The read-only view a handler receives: envelope plus optional lease,
-- deliberately without an 'AckHandle'. The framework owns finalization.
data Message es msg = Message
  { -- | Message metadata and payload
    envelope :: !(Envelope msg),
    -- | Optional lease for visibility timeout extension
    lease :: !(Maybe (Lease es))
  }

-- | Project the framework-side 'Ingested' to the handler-facing view.
toMessage :: Ingested es msg -> Message es msg
toMessage ingested =
  Message
    { envelope = ingested.envelope,
      lease = ingested.lease
    }

-- | Construct an 'Ingested' with no lease.
mkIngested :: Envelope msg -> AckHandle es -> Ingested es msg
mkIngested envelope ack =
  Ingested
    { envelope = envelope,
      ack = ack,
      lease = Nothing
    }
