{-# LANGUAGE OverloadedStrings #-}

module Shibuya.PolicySpec (spec) where

import Shibuya.Policy
import Test.Hspec
import Prelude hiding (Ordering)

spec :: Spec
spec = do
  describe "Ordering" $ do
    it "all constructors are distinguishable" $ do
      StrictInOrder `shouldNotBe` PartitionedInOrder
      PartitionedInOrder `shouldNotBe` Unordered
      StrictInOrder `shouldNotBe` Unordered

  describe "Concurrency" $ do
    it "all constructors are distinguishable" $ do
      Serial `shouldNotBe` Ahead 1
      Ahead 1 `shouldNotBe` Async 1
      Serial `shouldNotBe` Async 1

    it "Ahead preserves Int value" $ do
      let c = Ahead 42
      case c of
        Ahead n -> n `shouldBe` 42
        _ -> expectationFailure "wrong constructor"

    it "Async preserves Int value" $ do
      let c = Async 100
      case c of
        Async n -> n `shouldBe` 100
        _ -> expectationFailure "wrong constructor"

  describe "validatePolicy" $ do
    describe "StrictInOrder" $ do
      it "allows Serial" $ do
        validatePolicy StrictInOrder Serial `shouldBe` Right ()

      it "rejects Ahead" $ do
        validatePolicy StrictInOrder (Ahead 5) `shouldSatisfy` isLeft

      it "rejects Async" $ do
        validatePolicy StrictInOrder (Async 5) `shouldSatisfy` isLeft

    describe "PartitionedInOrder" $ do
      it "allows Serial" $ do
        validatePolicy PartitionedInOrder Serial `shouldBe` Right ()

      it "allows Ahead" $ do
        validatePolicy PartitionedInOrder (Ahead 10) `shouldBe` Right ()

      it "allows Async" $ do
        validatePolicy PartitionedInOrder (Async 10) `shouldBe` Right ()

    describe "Unordered" $ do
      it "allows Serial" $ do
        validatePolicy Unordered Serial `shouldBe` Right ()

      it "allows Ahead" $ do
        validatePolicy Unordered (Ahead 10) `shouldBe` Right ()

      it "allows Async" $ do
        validatePolicy Unordered (Async 10) `shouldBe` Right ()

-- Helper
isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft (Right _) = False
