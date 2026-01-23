-- | Types for the metrics server, including WebSocket protocol messages.
module Shibuya.Metrics.Types
  ( -- * WebSocket Protocol
    ClientMessage (..),
    ServerMessage (..),

    -- * Server Handle
    MetricsServer (..),
  )
where

import Control.Concurrent.Async (Async)
import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    object,
    withObject,
    withText,
    (.:),
    (.:?),
    (.=),
  )
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Network.Wai.Handler.Warp (Port)
import Shibuya.Runner.Metrics (MetricsMap, ProcessorId, ProcessorMetrics)

--------------------------------------------------------------------------------
-- WebSocket Protocol
--------------------------------------------------------------------------------

-- | Messages from client to server.
data ClientMessage
  = -- | Subscribe to all processor metrics
    SubscribeAll
  | -- | Subscribe to specific processors
    Subscribe ![ProcessorId]
  | -- | Unsubscribe from specific processors
    Unsubscribe ![ProcessorId]
  | -- | Ping for keepalive
    Ping
  deriving stock (Eq, Show, Generic)

instance ToJSON ClientMessage where
  toJSON SubscribeAll = object ["type" .= ("subscribe_all" :: Text)]
  toJSON (Subscribe pids) = object ["type" .= ("subscribe" :: Text), "processors" .= pids]
  toJSON (Unsubscribe pids) = object ["type" .= ("unsubscribe" :: Text), "processors" .= pids]
  toJSON Ping = object ["type" .= ("ping" :: Text)]

instance FromJSON ClientMessage where
  parseJSON = withObject "ClientMessage" $ \v -> do
    msgType <- v .: "type"
    case msgType :: Text of
      "subscribe_all" -> pure SubscribeAll
      "subscribe" -> Subscribe <$> v .: "processors"
      "unsubscribe" -> Unsubscribe <$> v .: "processors"
      "ping" -> pure Ping
      other -> fail $ "Unknown message type: " <> Text.unpack other

-- | Messages from server to client.
data ServerMessage
  = -- | Full metrics snapshot (sent on subscribe)
    MetricsSnapshot !MetricsMap
  | -- | Update for a single processor (sent on push)
    ProcessorUpdate !ProcessorId !ProcessorMetrics
  | -- | Pong response to ping
    Pong
  | -- | Server is shutting down
    Goodbye
  deriving stock (Eq, Show, Generic)

instance ToJSON ServerMessage where
  toJSON (MetricsSnapshot metrics) =
    object ["type" .= ("snapshot" :: Text), "metrics" .= metrics]
  toJSON (ProcessorUpdate pid pm) =
    object ["type" .= ("update" :: Text), "processor" .= pid, "metrics" .= pm]
  toJSON Pong = object ["type" .= ("pong" :: Text)]
  toJSON Goodbye = object ["type" .= ("goodbye" :: Text)]

instance FromJSON ServerMessage where
  parseJSON = withObject "ServerMessage" $ \v -> do
    msgType <- v .: "type"
    case msgType :: Text of
      "snapshot" -> MetricsSnapshot <$> v .: "metrics"
      "update" -> ProcessorUpdate <$> v .: "processor" <*> v .: "metrics"
      "pong" -> pure Pong
      "goodbye" -> pure Goodbye
      other -> fail $ "Unknown message type: " <> Text.unpack other

--------------------------------------------------------------------------------
-- Server Handle
--------------------------------------------------------------------------------

-- | Handle for a running metrics server.
data MetricsServer = MetricsServer
  { -- | Async handle for the server thread
    serverThread :: !(Async ()),
    -- | Port the server is running on
    serverPort :: !Port
  }
  deriving stock (Generic)
