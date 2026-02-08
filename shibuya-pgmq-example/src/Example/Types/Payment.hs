-- | Payment message type for the payments queue.
--
-- Payments use FIFO ordering by customerId to ensure
-- transactions for the same customer are processed in order.
module Example.Types.Payment
  ( Payment (..),
    PaymentMethod (..),
    PaymentStatus (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | A payment message.
--
-- The customerId field is used as the FIFO group key
-- to ensure payments for the same customer are processed in order.
data Payment = Payment
  { paymentId :: !Text,
    orderId :: !Text,
    customerId :: !Text, -- FIFO group key
    amount :: !Double,
    currency :: !Text,
    method :: !PaymentMethod,
    status :: !PaymentStatus
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Payment method.
data PaymentMethod
  = CreditCard
  | DebitCard
  | BankTransfer
  | Wallet
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Payment status.
data PaymentStatus
  = PaymentPending
  | PaymentProcessing
  | PaymentCompleted
  | PaymentFailed
  | PaymentRefunded
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
