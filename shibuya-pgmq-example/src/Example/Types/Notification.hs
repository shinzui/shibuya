-- | Notification message type for the notifications queue.
--
-- Notifications are processed with high throughput settings
-- (large batch size, prefetch enabled) since they don't require
-- ordering and can tolerate some message loss.
module Example.Types.Notification
  ( Notification (..),
    NotificationType (..),
    NotificationPriority (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | A notification message.
data Notification = Notification
  { notificationId :: !Text,
    userId :: !Text,
    notificationType :: !NotificationType,
    title :: !Text,
    body :: !Text,
    priority :: !NotificationPriority
  }
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Notification delivery channel.
data NotificationType
  = Email
  | SMS
  | Push
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Notification priority.
data NotificationPriority
  = Low
  | Normal
  | High
  | Urgent
  deriving stock (Show, Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)
