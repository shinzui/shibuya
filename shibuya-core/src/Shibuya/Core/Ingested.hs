-- | Ingested message type - what handlers receive.
-- Combines Broadway.Message + Acknowledger + optional lease.
-- Exactly one thing flows through the system.
module Shibuya.Core.Ingested
  ( Ingested (..),
    DeliveryStatus (..),
    Message (..),
    toMessage,
    mkIngested,
  )
where

import Effectful (Eff)

import Shibuya.Core.AckHandle (AckHandle)
import Shibuya.Core.Lease (Lease)
import Shibuya.Core.Types (Envelope)

-- | Adapter admission snapshot; a current answer does not reserve the delivery
-- against a subsequent revocation or concurrent retry.
data DeliveryStatus
  = -- | Invoke the handler and finalize normally.
    DeliveryCurrent
  | -- | Redelivery is arranged or the attempt is fenced. Skip handler and finalizer.
    DeliverySuperseded
  deriving stock (Eq, Show)

-- | Framework-side message with the adapter-provided ack finalizer.
-- Adapters construct this; application handlers receive @Message@ instead.
data Ingested es msg = Ingested
  { -- | Message metadata and payload
    envelope :: !(Envelope msg),
    -- | Handle for acknowledging the message
    ack :: !(AckHandle es),
    -- | Optional lease for visibility timeout extension
    lease :: !(Maybe (Lease es)),
    -- | Read once at processing admission (once per member on the batch path).
    -- Must return promptly, without side effects or synchronous exceptions;
    -- asynchronous cancellation propagates. Superseded deliveries own no metrics
    -- slot and receive no handler or finalizer call.
    deliveryStatus :: !(Eff es DeliveryStatus)
  }

-- | The read-only view a handler receives: envelope plus optional lease,
-- deliberately without an ack handle. The framework owns finalization.
data Message es msg = Message
  { -- | Message metadata and payload
    envelope :: !(Envelope msg),
    -- | Optional lease for visibility timeout extension
    lease :: !(Maybe (Lease es))
  }

-- | Project the framework-side value to the handler-facing view.
toMessage :: Ingested es msg -> Message es msg
toMessage ingested =
  Message
    { envelope = ingested.envelope,
      lease = ingested.lease
    }

-- | Construct an ingested message with no lease.
mkIngested :: Envelope msg -> AckHandle es -> Ingested es msg
mkIngested envelope ack =
  Ingested
    { envelope = envelope,
      ack = ack,
      lease = Nothing,
      deliveryStatus = pure DeliveryCurrent
    }
