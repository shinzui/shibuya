module Main (main) where

import Bench.Baseline qualified as Baseline
import Bench.Framework qualified as Framework
import Bench.Handler qualified as Handler
import Test.Tasty.Bench (defaultMain)

main :: IO ()
main =
  defaultMain
    [ Baseline.benchmarks,
      Framework.benchmarks,
      Handler.benchmarks
    ]
