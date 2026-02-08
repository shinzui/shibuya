-- | Order message type for the orders queue.
module Example.Types.Order
  ( Order (..),
    OrderItem (..),
    OrderStatus (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | An order message.
data Order = Order
  { orderId :: !Text,
    customerId :: !Text,
    items :: ![OrderItem],
    totalAmount :: !Double,
    status :: !OrderStatus
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | An item in an order.
data OrderItem = OrderItem
  { productId :: !Text,
    productName :: !Text,
    quantity :: !Int,
    unitPrice :: !Double
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Order status.
data OrderStatus
  = Pending
  | Processing
  | Shipped
  | Delivered
  | Cancelled
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
