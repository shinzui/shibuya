module Shibuya.Batch.TestHarness
  ( -- * Scenario model
    BatchScenario (..),
    genScenario,

    -- * Envelope builders
    mkEnvelope,
    scenarioEnvelopes,
    scenarioBatchKey,
    scenarioMsgIds,
    scenarioIntended,

    -- * Exactly-once checking
    finalizedExactlyOnce,
  )
where

import Data.List (sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Shibuya.Batch (BatchKey (..))
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Core.Types qualified as Core
import Test.QuickCheck

-- | A randomized batch schedule. Each message index @i@ in @[1 .. msgCount]@ has a
-- distinct 'MessageId' @"msg-i"@, an assigned 'BatchKey' (@keyOf ! i@), and an
-- intended finalized decision (@outcomeOf ! i@, always 'AckOk' or an
-- 'AckDeadLetter'). @batchSize@ and @batchTimeoutMs@ configure the batcher.
data BatchScenario = BatchScenario
  { msgCount :: !Int,
    batchSize :: !Int,
    batchTimeoutMs :: !Int,
    keyOf :: !(Map Int BatchKey),
    outcomeOf :: !(Map Int AckDecision)
  }
  deriving stock (Show)

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

-- | Generate a randomized scenario: 1..40 messages, a batch size that may be
-- smaller than, equal to, or larger than the message count (so some runs never
-- flush by size), a short timeout, 1..4 batch keys, and a per-message outcome that
-- is mostly 'AckOk' with an occasional dead-letter.
genScenario :: Gen BatchScenario
genScenario = do
  n <- choose (1, 40)
  bs <- choose (1, n + 5)
  toMs <- choose (20, 200)
  numKeys <- choose (1, min 4 n)
  keys <- vectorOf n (chooseKey numKeys)
  outs <- vectorOf n genOutcome
  pure
    BatchScenario
      { msgCount = n,
        batchSize = bs,
        batchTimeoutMs = toMs,
        keyOf = Map.fromList (zip [1 ..] keys),
        outcomeOf = Map.fromList (zip [1 ..] outs)
      }
  where
    chooseKey k = do
      j <- choose (1, k)
      pure (BatchKey ("k" <> tshow (j :: Int)))
    genOutcome =
      frequency
        [ (3, pure AckOk),
          (1, AckDeadLetter <$> elements [MaxRetriesExceeded, PoisonPill "qc", InvalidPayload "qc"])
        ]

instance Arbitrary BatchScenario where
  arbitrary = genScenario

-- | Build one envelope carrying a payload, with the given id number and batch key
-- stamped into the 'partition' field (so a pure @batchKey@ config function can
-- recover it).
mkEnvelope :: Int -> BatchKey -> Int -> Envelope Int
mkEnvelope i key payload =
  (Core.mkEnvelope (MessageId ("msg-" <> tshow i)) payload)
    { cursor = Just (CursorInt i),
      partition = Just key.unBatchKey
    }

-- | The envelopes for a scenario, in index order, each carrying its assigned key.
scenarioEnvelopes :: BatchScenario -> [Envelope Int]
scenarioEnvelopes s =
  [ mkEnvelope i (keyFor i) i
  | i <- [1 .. s.msgCount]
  ]
  where
    keyFor i = fromMaybe (BatchKey "default") (Map.lookup i s.keyOf)

-- | The pure @batchKey@ function to hand to 'BatchConfig': recover the key from the
-- envelope's partition, defaulting to @"default"@.
scenarioBatchKey :: Envelope Int -> BatchKey
scenarioBatchKey env = BatchKey (fromMaybe "default" env.partition)

-- | The set of message ids a scenario produces.
scenarioMsgIds :: BatchScenario -> [MessageId]
scenarioMsgIds s = [MessageId ("msg-" <> tshow i) | i <- [1 .. s.msgCount]]

-- | The intended finalized decision per message id.
scenarioIntended :: BatchScenario -> Map MessageId AckDecision
scenarioIntended s =
  Map.fromList
    [ (MessageId ("msg-" <> tshow i), fromMaybe AckOk (Map.lookup i s.outcomeOf))
    | i <- [1 .. s.msgCount]
    ]

-- | The successful-finalization checker. Given the raw tracked list of
-- @(messageId, decision)@ pairs (as recorded by a 'Shibuya.Adapter.Mock.TrackingAck',
-- which appends one entry per @finalize@ call) and the expected finalized decision
-- per id, return @Right ()@ iff every expected id appears exactly once and carries
-- its expected decision, and no unexpected id appears. Otherwise return a
-- human-readable explanation for use as a QuickCheck counterexample or an HSpec
-- failure message.
finalizedExactlyOnce ::
  [(MessageId, AckDecision)] ->
  Map MessageId AckDecision ->
  Either String ()
finalizedExactlyOnce tracked expected
  | not (null dupes) =
      Left ("finalized more than once: " <> show dupes)
  | trackedIds /= expectedIds =
      Left
        ( "id set mismatch: missing="
            <> show (expectedIds `minus` trackedIds)
            <> " extra="
            <> show (trackedIds `minus` expectedIds)
        )
  | not (null wrong) =
      Left ("wrong decision: " <> show wrong)
  | otherwise = Right ()
  where
    counts :: Map MessageId Int
    counts = Map.fromListWith (+) [(mid, 1 :: Int) | (mid, _) <- tracked]
    dupes = [mid | (mid, c) <- Map.toList counts, c /= 1]
    trackedIds = sort (Map.keys counts)
    expectedIds = sort (Map.keys expected)
    minus xs ys = filter (`notElem` ys) xs
    -- Since each id appears exactly once (checked above via dupes), a simple
    -- lookup of the single decision is well-defined here.
    got = Map.fromList tracked
    wrong =
      [ (mid, want, Map.lookup mid got)
      | (mid, want) <- Map.toList expected,
        Map.lookup mid got /= Just want
      ]
