-- | Baseline benchmarks using pure streamly.
-- These establish the performance floor that shibuya should approach.
module Bench.Baseline (benchmarks) where

import Control.DeepSeq (NFData, deepseq)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream (Stream)
import Streamly.Data.Stream qualified as Stream
import Test.Tasty.Bench (Benchmark, bench, bgroup, nfIO)

-- | Simple message type for benchmarking
data BenchMessage = BenchMessage
  { msgId :: !Int,
    msgPayload :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Generate a stream of messages
messageStream :: Int -> Stream IO BenchMessage
messageStream n =
  Stream.fromList
    [ BenchMessage i (Text.pack $ "payload-" <> show i)
    | i <- [1 .. n]
    ]

benchmarks :: Benchmark
benchmarks =
  bgroup
    "baseline-streamly"
    [ streamCreationBenchmarks,
      streamConsumptionBenchmarks,
      streamTransformBenchmarks
    ]

streamCreationBenchmarks :: Benchmark
streamCreationBenchmarks =
  bgroup
    "stream-creation"
    [ bench "100-msgs" $ nfIO $ createAndCount 100,
      bench "1000-msgs" $ nfIO $ createAndCount 1000,
      bench "10000-msgs" $ nfIO $ createAndCount 10000
    ]

streamConsumptionBenchmarks :: Benchmark
streamConsumptionBenchmarks =
  bgroup
    "stream-consumption"
    [ bench "fold-100" $ nfIO $ foldStream 100,
      bench "fold-1000" $ nfIO $ foldStream 1000,
      bench "fold-10000" $ nfIO $ foldStream 10000
    ]

streamTransformBenchmarks :: Benchmark
streamTransformBenchmarks =
  bgroup
    "stream-transform"
    [ bench "map-100" $ nfIO $ mapStream 100,
      bench "map-1000" $ nfIO $ mapStream 1000,
      bench "map-10000" $ nfIO $ mapStream 10000,
      bench "filter-map-100" $ nfIO $ filterMapStream 100,
      bench "filter-map-1000" $ nfIO $ filterMapStream 1000,
      bench "filter-map-10000" $ nfIO $ filterMapStream 10000
    ]

-- | Create stream and count elements
createAndCount :: Int -> IO Int
createAndCount n = Stream.fold Fold.length (messageStream n)

-- | Fold stream summing message IDs
foldStream :: Int -> IO Int
foldStream n = Stream.fold (Fold.foldl' (+) 0) (fmap (.msgId) (messageStream n))

-- | Map over stream elements
mapStream :: Int -> IO Int
mapStream n = do
  let transformed = fmap (\m -> m.msgId * 2) (messageStream n)
  result <- Stream.fold Fold.sum transformed
  result `deepseq` pure result

-- | Filter and map stream
filterMapStream :: Int -> IO Int
filterMapStream n = do
  let transformed =
        fmap (\m -> m.msgId * 2) $
          Stream.filter (\m -> m.msgId `mod` 2 == 0) $
            messageStream n
  result <- Stream.fold Fold.sum transformed
  result `deepseq` pure result
