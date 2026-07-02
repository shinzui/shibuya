{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

module Shibuya.Runner.PartitionOrderingSpec (spec) where

import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.Concurrent.STM (atomically, check, readTVar)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter.Mock (getTrackedDecisions, newTrackingAck, trackedListAdapter)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Core.Types qualified as Core
import Shibuya.Internal.Runner.Master (startMaster, stopMaster)
import Shibuya.Internal.Runner.Supervised (SupervisedProcessor (..), runSupervised)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Test.Hspec
import Test.QuickCheck
import UnliftIO.Concurrent (threadDelay)

data Payload = Payload
  { delayMicros :: !Int
  }
  deriving stock (Eq, Show)

data PartitionCase = PartitionCase
  { caseMessages :: ![(Maybe Text, Int)],
    caseConcurrency :: !Concurrency
  }
  deriving stock (Show)

instance Arbitrary PartitionCase where
  arbitrary = do
    messageCount <- chooseInt (1, 24)
    messages <-
      vectorOf messageCount $
        (,)
          <$> elements [Nothing, Just "p0", Just "p1", Just "p2"]
          <*> chooseInt (0, 2000)
    concurrency <-
      oneof
        [ Ahead <$> chooseInt (2, 8),
          Async <$> chooseInt (2, 8)
        ]
    pure PartitionCase {caseMessages = messages, caseConcurrency = concurrency}

spec :: Spec
spec = describe "Shibuya.Runner.PartitionOrdering" $ do
  it "finalizes each partition in arrival order and exactly once" $
    property $
      withMaxSuccess 30 $ \(PartitionCase messages concurrency) ->
        ioProperty $ do
          finalized <- runPartitioned messages concurrency
          let ids = makeIds (length messages)
              partitionById = Map.fromList (zip ids (map fst messages))
              finalizedIds = map fst finalized
              partitions = nub [p | Just p <- map fst messages]
              finalizedFor p =
                [ msgId
                | msgId <- finalizedIds,
                  Map.lookup msgId partitionById == Just (Just p)
                ]
              arrivedFor p =
                [ msgId
                | (msgId, Just p') <- zip ids (map fst messages),
                  p == p'
                ]
          pure $
            counterexample ("finalized=" <> show finalizedIds) $
              sort finalizedIds === sort ids
                .&&. conjoin [finalizedFor p === arrivedFor p | p <- partitions]

  it "respects the global concurrency bound" $ do
    maxInFlightRef <- newIORef (0 :: Int)
    currentInFlightRef <- newIORef (0 :: Int)

    _ <-
      runPartitionedWithHandler
        (zip (map Just ["p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7"]) (repeat 50_000))
        (Async 3)
        ( \_ -> do
            cur <-
              liftIO $
                atomicModifyIORef' currentInFlightRef (\n -> let n' = n + 1 in (n', n'))
            liftIO $ atomicModifyIORef' maxInFlightRef (\m -> (max m cur, ()))
            liftIO $ threadDelay 50_000
            liftIO $ atomicModifyIORef' currentInFlightRef (\n -> (n - 1, ()))
            pure AckOk
        )

    maxInFlight <- readIORef maxInFlightRef
    maxInFlight `shouldSatisfy` (<= 3)

  it "does not let a slow partition block fast partitions" $ do
    finalized <-
      runPartitioned
        [ (Just "slow", 80_000),
          (Just "fast", 1_000),
          (Just "slow", 80_000),
          (Just "fast", 1_000),
          (Just "slow", 80_000),
          (Just "fast", 1_000)
        ]
        (Async 4)

    let orderedIds = map fst finalized
        lastSlowIndex = fromMaybe maxBound $ elemIndex' "msg-4" orderedIds
        fastIndexes =
          map
            (`elemIndexOrMax` orderedIds)
            ["msg-1", "msg-3", "msg-5"]
    all (< lastSlowIndex) fastIndexes `shouldBe` True

runPartitioned ::
  [(Maybe Text, Int)] ->
  Concurrency ->
  IO [(MessageId, AckDecision)]
runPartitioned messages concurrency =
  runPartitionedWithHandler messages concurrency $ \ingested -> do
    let Message {envelope = Envelope {payload = Payload delay}} = ingested
    liftIO $ threadDelay delay
    pure AckOk

runPartitionedWithHandler ::
  [(Maybe Text, Int)] ->
  Concurrency ->
  (forall es. (IOE :> es) => Message es Payload -> Eff es AckDecision) ->
  IO [(MessageId, AckDecision)]
runPartitionedWithHandler messages concurrency handler =
  runEff $ runTracingNoop $ do
    tracking <- newTrackingAck
    let envs = zipWith mkEnvelope [0 :: Int ..] messages
        adapter = trackedListAdapter tracking envs
    master <- startMaster IgnoreAll
    sp <- runSupervised master 50 (ProcessorId "partitioned") PartitionedInOrder concurrency adapter handler
    liftIO $ atomically $ readTVar sp.done >>= check
    decisions <- getTrackedDecisions tracking
    stopMaster master
    pure (reverse decisions)

mkEnvelope :: Int -> (Maybe Text, Int) -> Envelope Payload
mkEnvelope i (partition, delayMicros) =
  (Core.mkEnvelope (makeId i) Payload {delayMicros})
    { cursor = Just (CursorInt i),
      partition = partition
    }

makeIds :: Int -> [MessageId]
makeIds n = map makeId [0 .. n - 1]

makeId :: Int -> MessageId
makeId i = MessageId ("msg-" <> Text.pack (show i))

elemIndexOrMax :: MessageId -> [MessageId] -> Int
elemIndexOrMax needle haystack = fromMaybe maxBound (elemIndex' needle haystack)

elemIndex' :: (Eq a) => a -> [a] -> Maybe Int
elemIndex' needle = go 0
  where
    go _ [] = Nothing
    go i (x : xs)
      | x == needle = Just i
      | otherwise = go (i + 1) xs
