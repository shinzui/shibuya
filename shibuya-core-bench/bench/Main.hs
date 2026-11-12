module Main (main) where

import Bench.Baseline qualified as Baseline
import Bench.Concurrency qualified as Concurrency
import Bench.DeadLetterReason qualified as DeadLetterReason
import Bench.Framework qualified as Framework
import Bench.Handler qualified as Handler
import Bench.HotPath qualified as HotPath
import Bench.Lifecycle qualified as Lifecycle
import Bench.Tracing qualified as Tracing
import Test.Tasty.Bench (defaultMain)

main :: IO ()
main = do
  -- Built once, outside every measured cell; see "Bench.Tracing".
  tracer <- Tracing.newBenchTracer
  defaultMain
    [ Baseline.benchmarks,
      Framework.benchmarks,
      Handler.benchmarks,
      Concurrency.benchmarks,
      HotPath.benchmarks,
      Lifecycle.benchmarks,
      DeadLetterReason.benchmarks,
      Tracing.benchmarks tracer
    ]
