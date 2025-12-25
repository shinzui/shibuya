{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Core.AckSpec (spec) where

import Data.Time (secondsToNominalDiffTime)
import Shibuya.Core.Ack
import Test.Hspec

spec :: Spec
spec = do
  describe "RetryDelay" $ do
    it "wraps NominalDiffTime" $ do
      let delay = RetryDelay (secondsToNominalDiffTime 30)
      delay.unRetryDelay `shouldBe` secondsToNominalDiffTime 30

    it "supports Eq" $ do
      let d1 = RetryDelay (secondsToNominalDiffTime 10)
          d2 = RetryDelay (secondsToNominalDiffTime 10)
          d3 = RetryDelay (secondsToNominalDiffTime 20)
      d1 `shouldBe` d2
      d1 `shouldNotBe` d3

  describe "DeadLetterReason" $ do
    it "distinguishes all constructors" $ do
      let r1 = PoisonPill "bad message"
          r2 = InvalidPayload "parse error"
          r3 = MaxRetriesExceeded
      r1 `shouldNotBe` r2
      r2 `shouldNotBe` r3
      r1 `shouldNotBe` r3

    it "PoisonPill carries message" $ do
      let r = PoisonPill "corrupt data"
      case r of
        PoisonPill msg -> msg `shouldBe` "corrupt data"
        _ -> expectationFailure "wrong constructor"

    it "InvalidPayload carries message" $ do
      let r = InvalidPayload "JSON decode failed"
      case r of
        InvalidPayload msg -> msg `shouldBe` "JSON decode failed"
        _ -> expectationFailure "wrong constructor"

  describe "HaltReason" $ do
    it "HaltOrderedStream carries message" $ do
      let r = HaltOrderedStream "ordering violation"
      case r of
        HaltOrderedStream msg -> msg `shouldBe` "ordering violation"
        _ -> expectationFailure "wrong constructor"

    it "HaltFatal carries message" $ do
      let r = HaltFatal "database connection lost"
      case r of
        HaltFatal msg -> msg `shouldBe` "database connection lost"
        _ -> expectationFailure "wrong constructor"

  describe "AckDecision" $ do
    it "distinguishes all constructors" $ do
      let d1 = AckOk
          d2 = AckRetry (RetryDelay 10)
          d3 = AckDeadLetter MaxRetriesExceeded
          d4 = AckHalt (HaltFatal "error")
      d1 `shouldNotBe` d2
      d2 `shouldNotBe` d3
      d3 `shouldNotBe` d4
      d1 `shouldNotBe` d4

    it "AckOk equals AckOk" $ do
      AckOk `shouldBe` AckOk

    it "AckRetry carries delay" $ do
      let delay = RetryDelay (secondsToNominalDiffTime 60)
          decision = AckRetry delay
      case decision of
        AckRetry d -> d `shouldBe` delay
        _ -> expectationFailure "wrong constructor"

    it "AckDeadLetter carries reason" $ do
      let reason = PoisonPill "unprocessable"
          decision = AckDeadLetter reason
      case decision of
        AckDeadLetter r -> r `shouldBe` reason
        _ -> expectationFailure "wrong constructor"

    it "AckHalt carries reason" $ do
      let reason = HaltOrderedStream "must stop"
          decision = AckHalt reason
      case decision of
        AckHalt r -> r `shouldBe` reason
        _ -> expectationFailure "wrong constructor"
