module Shibuya.Metrics.TypesSpec (spec) where

import Data.Aeson (FromJSON, ToJSON, Value, eitherDecode, encode, object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Metrics.TestSupport (fixtureMetrics)
import Shibuya.Metrics.Types
  ( ClientMessage (..),
    ProcessorTerminalStatus (..),
    ServerMessage (..),
  )
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = do
  describe "ClientMessage JSON contract" $ do
    messageCase SubscribeAll $ object ["type" .= ("subscribe_all" :: String)]
    messageCase (Subscribe [ProcessorId "alpha"]) $
      object ["type" .= ("subscribe" :: String), "processors" .= ["alpha" :: String]]
    messageCase (Unsubscribe [ProcessorId "alpha"]) $
      object ["type" .= ("unsubscribe" :: String), "processors" .= ["alpha" :: String]]
    messageCase Ping $ object ["type" .= ("ping" :: String)]

    it "rejects an unknown client message tag" $
      (eitherDecode "{\"type\":\"unknown\"}" :: Either String ClientMessage)
        `shouldSatisfy` isLeft

  describe "ServerMessage JSON contract" $ do
    let processing = fixtureMetrics Map.! ProcessorId "processing"
    messageCase (MetricsSnapshot fixtureMetrics) $
      object ["type" .= ("snapshot" :: String), "metrics" .= fixtureMetrics]
    messageCase (ProcessorUpdate (ProcessorId "processing") processing) $
      object
        [ "type" .= ("update" :: String),
          "processor" .= ("processing" :: String),
          "metrics" .= processing
        ]
    messageCase Pong $ object ["type" .= ("pong" :: String)]
    messageCase (ProcessorTerminal (ProcessorId "alpha") TerminalStopped) $
      object
        [ "type" .= ("terminal" :: String),
          "processor" .= ("alpha" :: String),
          "status" .= ("stopped" :: String)
        ]
    messageCase
      (ProcessorTerminal (ProcessorId "alpha") (TerminalFailed "boom" (Just "message-1")))
      $ object
        [ "type" .= ("terminal" :: String),
          "processor" .= ("alpha" :: String),
          "status" .= ("failed" :: String),
          "error" .= ("boom" :: String),
          "messageId" .= (Just "message-1" :: Maybe String)
        ]
    messageCase (ServerError "invalid_message" "bad input") $
      object ["type" .= ("error" :: String), "code" .= ("invalid_message" :: String), "message" .= ("bad input" :: String)]
    messageCase Goodbye $ object ["type" .= ("goodbye" :: String)]

    it "characterizes strict legacy decoders and extension-tolerant consumers" $ do
      let err = ServerError "queue_overflow" "resnapshot"
          legacy = withObject "LegacyServerMessage" $ \v -> do
            tag <- v .: "type"
            if (tag :: Text) `elem` ["snapshot", "update", "terminal", "pong", "goodbye"]
              then pure tag
              else fail "unknown legacy tag"
      parseEither legacy (toJSON err) `shouldSatisfy` isLeft
      eitherDecode @Value (encode err) `shouldBe` Right (toJSON err)

    it "rejects an unknown server message tag" $
      (eitherDecode "{\"type\":\"unknown\"}" :: Either String ServerMessage)
        `shouldSatisfy` isLeft

messageCase :: (Eq a, Show a, ToJSON a, FromJSON a) => a -> Value -> Spec
messageCase message expected =
  it (show message) $ do
    toJSON message `shouldBe` expected
    eitherDecode (encode message) `shouldBe` Right message

isLeft :: Either a b -> Bool
isLeft = \case Left _ -> True; Right _ -> False
