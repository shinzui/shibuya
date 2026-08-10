{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Core.AckSpec (spec) where

import Data.Text qualified as Text
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
          code = validCode "example.policy.rejected"
          r4 = ApplicationFailure code "policy rejected"
      r1 `shouldNotBe` r2
      r2 `shouldNotBe` r3
      r1 `shouldNotBe` r3
      r3 `shouldNotBe` r4

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

    describe "mkDeadLetterCode" $ do
      it "accepts namespaced lowercase application codes" $ do
        fmap deadLetterCodeText (mkDeadLetterCode "keiro.router.selection.recipient_overflow")
          `shouldBe` Right "keiro.router.selection.recipient_overflow"

      it "accepts the 128-character boundary" $ do
        let code = "a." <> Text.replicate 126 "b"
        fmap deadLetterCodeText (mkDeadLetterCode code) `shouldBe` Right code

      it "rejects each invalid grammar boundary" $ do
        let invalidCodes =
              [ "",
                "unqualified",
                "keiro.Router",
                "keiro.router-selection",
                "keiro..selection",
                "1keiro.router",
                "keiro.1router",
                "keiro.routér",
                "shibuya.router",
                "a." <> Text.replicate 127 "b"
              ]
        mapM_ (\code -> mkDeadLetterCode code `shouldSatisfy` isLeft) invalidCodes

      it "identifies the rejected code and failed rule" $ do
        mkDeadLetterCode "Keiro.router"
          `shouldBe` Left "invalid dead-letter code \"Keiro.router\": segment \"Keiro\" must match [a-z][a-z0-9_]*"

    describe "dead-letter projections and rendering" $ do
      it "preserves the built-in contracts exactly" $ do
        let cases =
              [ (PoisonPill "x", "poison_pill", Just "x", "poison_pill: x"),
                (InvalidPayload "x", "invalid_payload", Just "x", "invalid_payload: x"),
                (MaxRetriesExceeded, "max_retries_exceeded", Nothing, "max_retries_exceeded")
              ]
        mapM_
          ( \(reason, code, detail, rendered) -> do
              deadLetterCodeText (deadLetterReasonCode reason) `shouldBe` code
              deadLetterReasonDetail reason `shouldBe` detail
              renderDeadLetterReason reason `shouldBe` rendered
          )
          cases

      it "preserves an application code and detail" $ do
        let code = validCode "keiro.router.selection.recipient_overflow"
            reason = ApplicationFailure code "selected 101 recipients; configured limit is 100"
        deadLetterCodeText (deadLetterReasonCode reason)
          `shouldBe` "keiro.router.selection.recipient_overflow"
        deadLetterReasonDetail reason
          `shouldBe` Just "selected 101 recipients; configured limit is 100"
        renderDeadLetterReason reason
          `shouldBe` "keiro.router.selection.recipient_overflow: selected 101 recipients; configured limit is 100"

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

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

validCode :: Text.Text -> DeadLetterCode
validCode code =
  case mkDeadLetterCode code of
    Left err -> error $ "invalid test fixture: " <> show err
    Right valid -> valid
