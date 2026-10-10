module Shibuya.Metrics.OutboundQueueSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Shibuya.Metrics.Outbound qualified as Q
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

spec :: Spec
spec = describe "bounded outbound queue" $ do
  it "preserves frame and byte bounds and exact counters over exhaustive transition traces" $ do
    let actions =
          [ Add Q.Required 1,
            Add Q.Required 7,
            Add Q.Update 3,
            Add Q.Update 12,
            Add Q.Ephemeral 2,
            Pop,
            Discard
          ]
        step q action = case action of
          Add keep size -> snd $ Q.enqueue (Q.Limits 3 10) [value keep size] q
          Pop -> maybe q snd $ Q.pop q
          Discard -> Q.discardUpdates q
        walk depth q = do
          Q.queuedFrames q `shouldBe` length (Q.entries q)
          Q.queuedBytes q `shouldBe` sum (map (BS.length . Q.payload) $ Q.entries q)
          Q.queuedFrames q `shouldSatisfy` (<= 3)
          Q.queuedBytes q `shouldSatisfy` (<= 10)
          if depth == (0 :: Int) then pure () else forM_ actions (walk (depth - 1) . step q)
    walk 5 Q.empty

  it "evicts updates oldest-first while retaining required order" $ do
    let a = value Q.Update 1
        b = value Q.Required 2
        c = value Q.Update 3
        (_, q) = Q.enqueue (Q.Limits 3 10) [a, b, c] Q.empty
        (outcome, next) = Q.enqueue (Q.Limits 3 10) [value Q.Required 4] q
    outcome `shouldBe` Q.DroppedUpdates
    map (BS.length . Q.payload) (Q.entries next) `shouldBe` [2, 3, 4]

  it "refuses required saturation and oversized snapshots without dropping required frames" $ do
    let (_, q) = Q.enqueue (Q.Limits 2 10) [value Q.Required 4, value Q.Required 4] Q.empty
    Q.enqueue (Q.Limits 2 10) [value Q.Required 1] q `shouldBe` (Q.MustClose, q)
    Q.enqueue (Q.Limits 2 10) [value Q.Required 11] Q.empty `shouldBe` (Q.MustClose, Q.empty)

  it "admits recovery batches wholly and consecutively after earlier required frames" $ do
    let (_, q) = Q.enqueue (Q.Limits 3 10) [value Q.Required 1, value Q.Update 3] Q.empty
        batch = [value Q.Required 4, value Q.Required 5]
        (result, next) = Q.enqueue (Q.Limits 3 10) batch (Q.discardUpdates q)
    result `shouldBe` Q.Enqueued
    Q.entries next `shouldBe` value Q.Required 1 : batch
    Q.enqueue (Q.Limits 2 10) batch q `shouldBe` (Q.MustClose, q)

  it "marks rejected oversized updates for recovery, but not lost pongs" $ do
    fst (Q.enqueue (Q.Limits 2 10) [value Q.Update 11] Q.empty) `shouldBe` Q.DroppedUpdates
    fst (Q.enqueue (Q.Limits 2 10) [value Q.Ephemeral 11] Q.empty) `shouldBe` Q.Enqueued

  it "removes unsent old-generation updates without deleting required snapshots" $ do
    let snapshot = Q.frame 2 Q.Required "snapshot"
        update = Q.frame 1 Q.Update "old"
        (_, q) = Q.enqueue (Q.Limits 2 30) [update, snapshot] Q.empty
    Q.entries (Q.discardUpdates q) `shouldBe` [snapshot]

value :: Q.Retention -> Int -> Q.Frame
value keep size = Q.frame 0 keep (BS.replicate size 97)

data Action = Add Q.Retention Int | Pop | Discard
