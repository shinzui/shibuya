{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Core.RetrySpec (spec) where

import Data.Time (nominalDiffTimeToSeconds)
import Effectful (runEff)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Retry
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Test.Hspec
import Test.QuickCheck

secondsOf :: RetryDelay -> Double
secondsOf (RetryDelay d) = realToFrac (nominalDiffTimeToSeconds d)

testEnvelope :: Maybe Attempt -> Envelope ()
testEnvelope a =
  Envelope
    { messageId = MessageId "test",
      cursor = Nothing,
      partition = Nothing,
      enqueuedAt = Nothing,
      traceContext = Nothing,
      attempt = a,
      payload = ()
    }

spec :: Spec
spec = do
  describe "exponentialBackoffPure" $ do
    describe "NoJitter" $ do
      let p = defaultBackoffPolicy {jitter = NoJitter}
      it "delay = base at attempt 0" $
        secondsOf (exponentialBackoffPure p (Attempt 0) 0) `shouldBe` 1.0
      it "delay doubles each attempt" $ do
        secondsOf (exponentialBackoffPure p (Attempt 1) 0) `shouldBe` 2.0
        secondsOf (exponentialBackoffPure p (Attempt 2) 0) `shouldBe` 4.0
        secondsOf (exponentialBackoffPure p (Attempt 3) 0) `shouldBe` 8.0
      it "delay clamps to maxDelay" $
        -- 2^20 = 1048576 ≫ 300 seconds
        secondsOf (exponentialBackoffPure p (Attempt 20) 0) `shouldBe` 300.0
      it "ignores the jitter sample" $
        secondsOf (exponentialBackoffPure p (Attempt 3) 0)
          `shouldBe` secondsOf (exponentialBackoffPure p (Attempt 3) 0.999)

    describe "FullJitter" $ do
      let p = defaultBackoffPolicy {jitter = FullJitter}
      it "delay at sample 0 is 0" $
        secondsOf (exponentialBackoffPure p (Attempt 5) 0) `shouldBe` 0.0
      it "delay at sample ~1 approaches baseExp" $
        secondsOf (exponentialBackoffPure p (Attempt 2) 0.999)
          `shouldSatisfy` (\x -> x > 3.99 && x <= 4.0)
      it "delay never exceeds the clamped baseExp" $
        property $ \(NonNegative n) ->
          forAll (choose (0.0, 0.999999)) $ \sample ->
            let attemptN = Attempt (fromIntegral (n :: Int))
                delay = secondsOf (exponentialBackoffPure p attemptN sample)
             in delay >= 0 && delay <= 300

    describe "EqualJitter" $ do
      let p = defaultBackoffPolicy {jitter = EqualJitter}
      it "delay at sample 0 is half the baseExp" $
        secondsOf (exponentialBackoffPure p (Attempt 2) 0) `shouldBe` 2.0
      it "delay at sample ~1 approaches the full baseExp" $
        secondsOf (exponentialBackoffPure p (Attempt 2) 0.999)
          `shouldSatisfy` (\x -> x > 3.99 && x <= 4.0)
      it "delay is in [baseExp/2, baseExp]" $
        property $ \(NonNegative n) ->
          forAll (choose (0.0, 0.999999)) $ \sample ->
            let attemptN = Attempt (fromIntegral (n :: Int))
                delay = secondsOf (exponentialBackoffPure p attemptN sample)
             in delay >= 0 && delay <= 300

    describe "Attempt 0" $ do
      it "with NoJitter equals base" $
        secondsOf (exponentialBackoffPure (defaultBackoffPolicy {jitter = NoJitter}) (Attempt 0) 0)
          `shouldBe` 1.0
      it "with FullJitter is in [0, base)" $
        property $
          forAll (choose (0.0, 0.999999)) $ \sample ->
            let delay = secondsOf (exponentialBackoffPure (defaultBackoffPolicy {jitter = FullJitter}) (Attempt 0) sample)
             in delay >= 0 && delay < 1.0

  describe "retryWithBackoff" $ do
    it "produces AckRetry when attempt is set" $ do
      decision <- runEff (retryWithBackoff defaultBackoffPolicy (testEnvelope (Just (Attempt 1))))
      case decision of
        AckRetry _ -> pure ()
        other -> expectationFailure $ "expected AckRetry, got " <> show other

    it "produces AckRetry when attempt is Nothing (treats as Attempt 0)" $ do
      decision <- runEff (retryWithBackoff defaultBackoffPolicy (testEnvelope Nothing))
      case decision of
        AckRetry (RetryDelay d) ->
          -- baseExp at Attempt 0 = base = 1s, FullJitter -> [0, 1)
          realToFrac (nominalDiffTimeToSeconds d) `shouldSatisfy` (\x -> x >= 0 && x < (1.0 :: Double))
        other -> expectationFailure $ "expected AckRetry, got " <> show other

  describe "exponentialBackoff (effectful)" $ do
    it "samples a delay in [0, baseExp] for FullJitter" $ do
      RetryDelay d <- runEff (exponentialBackoff defaultBackoffPolicy (Attempt 4))
      -- baseExp at Attempt 4 = 1 * 2^4 = 16s, FullJitter -> [0, 16)
      realToFrac (nominalDiffTimeToSeconds d) `shouldSatisfy` (\x -> x >= 0 && x < (16.0 :: Double))
