{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Core.TypesSpec (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Shibuya.Core.Types
import Test.Hspec

spec :: Spec
spec = do
  describe "MessageId" $ do
    it "supports Eq" $ do
      MessageId "abc" `shouldBe` MessageId "abc"
      MessageId "abc" `shouldNotBe` MessageId "xyz"

    it "supports Ord for Map keys" $ do
      MessageId "a" `compare` MessageId "b" `shouldBe` LT
      MessageId "b" `compare` MessageId "a" `shouldBe` GT
      MessageId "a" `compare` MessageId "a" `shouldBe` EQ

    it "supports IsString for OverloadedStrings" $ do
      let msgId :: MessageId = "test-message"
      msgId.unMessageId `shouldBe` "test-message"

  describe "Cursor" $ do
    it "CursorInt compares numerically" $ do
      CursorInt 1 `compare` CursorInt 2 `shouldBe` LT
      CursorInt 10 `compare` CursorInt 2 `shouldBe` GT

    it "CursorText compares lexicographically" $ do
      CursorText "a" `compare` CursorText "b" `shouldBe` LT
      CursorText "z" `compare` CursorText "a" `shouldBe` GT

    it "CursorInt comes before CursorText in Ord" $ do
      -- This is the derived Ord behavior
      CursorInt 999 `compare` CursorText "a" `shouldBe` LT

  describe "Envelope" $ do
    it "Functor: fmap id == id" $ do
      let env = testEnvelope (42 :: Int)
      fmap id env `shouldBe` env

    it "Functor: fmap (f . g) == fmap f . fmap g" $ do
      let env = testEnvelope (1 :: Int)
          f = (+ 1)
          g = (* 2)
      fmap (f . g) env `shouldBe` (fmap f . fmap g) env

    it "preserves all fields through fmap" $ do
      let env = testEnvelope ("hello" :: String)
          mapped = fmap length env
      mapped.messageId `shouldBe` env.messageId
      mapped.cursor `shouldBe` env.cursor
      mapped.partition `shouldBe` env.partition
      mapped.enqueuedAt `shouldBe` env.enqueuedAt
      mapped.traceContext `shouldBe` env.traceContext
      mapped.payload `shouldBe` 5

-- Test helper
testEnvelope :: msg -> Envelope msg
testEnvelope msg =
  Envelope
    { messageId = MessageId "test-id",
      cursor = Just (CursorInt 42),
      partition = Just "partition-0",
      enqueuedAt = Just testTime,
      traceContext = Nothing,
      payload = msg
    }

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2024 1 1) 0
