module Shibuya.Runner.BatcherSpec (spec) where

import Control.Concurrent (threadDelay)
import Data.List (sort)
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Effectful (Effect)
import Shibuya.Batch
  ( BatchConfig (..),
    BatchInfo (..),
    BatchKey (..),
    BatchTrigger (..),
  )
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..), mkIngested)
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Internal.Runner.Batcher
  ( ReadyBatch,
    emptyBatcherState,
    runBatcher,
    stepArrival,
    stepFlush,
    stepTick,
  )
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import Test.QuickCheck

-- The engine is parameterized by an effect stack and payload; the pure core
-- treats them as phantom. We pick es = 'E' (an empty effect stack, kind pinned
-- to '[Effect]') and msg = String for the tests.

type E = ('[] :: [Effect])

tshow :: Int -> Text
tshow = Text.pack . show

-- | Build a no-op-ack Ingested with a unique id, a sequence cursor, and a
-- partition equal to its batch key.
mkIng :: Int -> BatchKey -> Ingested E String
mkIng i (BatchKey k) =
  mkIngested
    ( (mkEnvelope (MessageId ("m-" <> tshow i)) ("payload-" <> show i))
        { cursor = Just (CursorInt i),
          partition = Just k
        }
    )
    (AckHandle (\_ -> pure ()))

-- Key the config on the message's partition (Just k -> BatchKey k).
partitionKeyConfig :: Int -> BatchConfig E String
partitionKeyConfig sz =
  BatchConfig
    { batchSize = sz,
      batchTimeout = 5,
      batchKey = \env -> BatchKey (fromMaybe "default" env.partition),
      tickInterval = Nothing
    }

baseTime :: UTCTime
baseTime = UTCTime (fromGregorian 2026 1 1) 0

-- | Run a synthetic event list through the pure core and collect emitted batches.
-- Events carry their own virtual time; a final flush drains the remainder so the
-- conservation property can compare the full input against the full output.
data Ev
  = EvArr Int BatchKey -- an arrival: unique id, key
  | EvTick -- a ticker scan
  deriving stock (Show)

runEvents :: BatchConfig E String -> [(Double, Ev)] -> [ReadyBatch E String]
runEvents cfg = go emptyBatcherState
  where
    go st [] = snd (stepFlush st)
    go st ((secs, ev) : rest) =
      let now = addUTCTime (realToFrac secs) baseTime
          (st', out) = case ev of
            EvArr i k -> stepArrival cfg now (mkIng i k) st
            EvTick -> stepTick cfg now st
       in out ++ go st' rest

batchIds :: [ReadyBatch E String] -> [MessageId]
batchIds bs = [ing.envelope.messageId | (_, ne) <- bs, ing <- NE.toList ne]

batchCursors :: NE.NonEmpty (Ingested E String) -> [Int]
batchCursors ne = [c | ing <- NE.toList ne, Just (CursorInt c) <- [ing.envelope.cursor]]

spec :: Spec
spec = describe "Shibuya.Internal.Runner.Batcher" $ do
  describe "pure core (deterministic, no threads)" $ do
    it "emits a size-triggered batch of exactly batchSize" $ do
      let cfg = partitionKeyConfig 2
          evs = [(0, EvArr 0 "a"), (0, EvArr 1 "a")]
          out = runEvents cfg evs
      map (\(info, _) -> (info.trigger, info.size)) out
        `shouldBe` [(TriggerSize, 2)]
      batchIds out `shouldBe` [MessageId "m-0", MessageId "m-1"]

    it "keeps different keys in independent groups" $ do
      let cfg = partitionKeyConfig 2
          evs = [(0, EvArr 0 "a"), (0, EvArr 1 "b"), (0, EvArr 2 "a"), (0, EvArr 3 "b")]
          out = runEvents cfg evs
      -- Two size batches, one per key; both size 2.
      map (\(info, _) -> (info.batchKey, info.size, info.trigger)) out
        `shouldMatchList` [(BatchKey "a", 2, TriggerSize), (BatchKey "b", 2, TriggerSize)]

    it "flushes a partial group at end of input with TriggerFlush" $ do
      let cfg = partitionKeyConfig 10
          evs = [(0, EvArr 0 "a"), (0, EvArr 1 "a")]
          out = runEvents cfg evs
      map (\(info, _) -> (info.trigger, info.size)) out `shouldBe` [(TriggerFlush, 2)]

    it "emits a timeout batch once batchTimeout has elapsed" $ do
      let cfg = partitionKeyConfig 10 -- large size so only timeout fires
      -- first message at t=0, tick at t=5 (== batchTimeout) fires it
          evs = [(0, EvArr 0 "a"), (5, EvTick)]
          out = runEvents cfg evs
      map (\(info, _) -> (info.trigger, info.size)) out `shouldBe` [(TriggerTimeout, 1)]

    it "does not emit on a tick before the timeout has elapsed" $ do
      let cfg = partitionKeyConfig 10
          evs = [(0, EvArr 0 "a"), (4, EvTick)] -- 4s < 5s timeout
          -- only the final flush emits
          out = runEvents cfg evs
      map (\(info, _) -> info.trigger) out `shouldBe` [TriggerFlush]

    it "copies the first message's partition into BatchInfo" $ do
      let cfg = partitionKeyConfig 2
          out = runEvents cfg [(0, EvArr 0 "tenant-7"), (0, EvArr 1 "tenant-7")]
      map (\(info, _) -> info.partition) out `shouldBe` [Just "tenant-7"]

  describe "message conservation (property)" $ do
    it "every input message appears in exactly one emitted batch" $
      property prop_conservation

    it "within each emitted batch, cursors are strictly ascending (per-key FIFO)" $
      property prop_fifo

    it "every TriggerSize batch has size == batchSize" $
      property prop_sizeTrigger

  describe "IO engine runBatcher" $ do
    it "conserves messages over a finite stream" $ do
      let cfg = partitionKeyConfig 3
          ings = [mkIng i (BatchKey (if even i then "a" else "b")) | i <- [0 .. 19]]
      out <- Stream.fold Fold.toList (runBatcher 8 cfg (Stream.fromList ings))
      sort (batchIds out) `shouldBe` sort [ing.envelope.messageId | ing <- ings]

    it "emits full size-3 batches for a single key" $ do
      let cfg = partitionKeyConfig 3
          ings = [mkIng i "a" | i <- [0 .. 6]] -- 7 messages
      out <- Stream.fold Fold.toList (runBatcher 8 cfg (Stream.fromList ings))
      map (\(info, _) -> (info.trigger, info.size)) out
        `shouldBe` [(TriggerSize, 3), (TriggerSize, 3), (TriggerFlush, 1)]

    it "emits a timeout batch on a slow stream before it ends" $ do
      -- A stream that yields message 0, then stalls > batchTimeout before 1.
      let cfg =
            (partitionKeyConfig 100) -- big size => only timeout/flush can fire
              { batchTimeout = 0.1, -- 100 ms
                tickInterval = Just 0.02 -- scan every 20 ms
              }
          slow =
            Stream.unfoldrM
              ( \n ->
                  if n >= 2
                    then pure Nothing
                    else do
                      -- delay before the SECOND message so message 0 times out
                      if n == 1 then threadDelay 250000 else pure ()
                      pure (Just (mkIng n "a", n + 1))
              )
              (0 :: Int)
      out <- Stream.fold Fold.toList (runBatcher 8 cfg slow)
      any (\(info, _) -> info.trigger == TriggerTimeout) out `shouldBe` True
      sort (batchIds out) `shouldBe` [MessageId "m-0", MessageId "m-1"]

-- QuickCheck generators and properties -------------------------------------

-- | A random schedule: arrivals with unique ids and random keys, interspersed
-- with ticks, plus a random batchSize. Time advances 1s per event; batchTimeout
-- is fixed at 5s in partitionKeyConfig, so ticks can fire real timeout batches.
genSchedule :: Gen (Int, [(Double, Ev)])
genSchedule = do
  sz <- choose (1, 8)
  n <- choose (0, 60)
  keys <- vectorOf n (elements ["a", "b", "c"])
  let arrivals = zipWith EvArr [0 ..] (map BatchKey keys)
  -- Interleave ticks randomly.
  evs <- interleaveTicks arrivals
  let timed = zip (map fromIntegral [0 :: Int ..]) evs
  pure (sz, timed)
  where
    interleaveTicks [] = pure []
    interleaveTicks (a : as) = do
      addTick <- arbitrary
      rest <- interleaveTicks as
      pure (if addTick then a : EvTick : rest else a : rest)

arrivalIds :: [(Double, Ev)] -> [MessageId]
arrivalIds evs = [MessageId ("m-" <> tshow i) | (_, EvArr i _) <- evs]

prop_conservation :: Property
prop_conservation = forAll genSchedule $ \(sz, evs) ->
  let cfg = partitionKeyConfig sz
      out = runEvents cfg evs
   in sort (batchIds out) === sort (arrivalIds evs)

prop_fifo :: Property
prop_fifo = forAll genSchedule $ \(sz, evs) ->
  let cfg = partitionKeyConfig sz
      out = runEvents cfg evs
   in conjoin [strictlyAscending (batchCursors ne) | (_, ne) <- out]
  where
    strictlyAscending xs = xs === sort xs

prop_sizeTrigger :: Property
prop_sizeTrigger = forAll genSchedule $ \(sz, evs) ->
  let cfg = partitionKeyConfig sz
      out = runEvents cfg evs
   in conjoin
        [ info.size === sz
        | (info, _) <- out,
          info.trigger == TriggerSize
        ]
