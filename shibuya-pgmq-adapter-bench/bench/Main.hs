module Main (main) where

import Bench.Ack qualified as Ack
import Bench.Concurrent qualified as Concurrent
import Bench.Fifo qualified as Fifo
import Bench.MultiQueue qualified as MultiQueue
import Bench.Raw qualified as Raw
import Bench.Read qualified as Read
import Bench.Send qualified as Send
import Bench.Throughput qualified as Throughput
import BenchConfig (loadConfig)
import BenchSetup (installPgmqSchema, withBenchPool)
import Test.Tasty.Bench (defaultMain)

main :: IO ()
main = do
  config <- loadConfig
  withBenchPool config $ \pool -> do
    -- Install pgmq schema (idempotent)
    installPgmqSchema pool

    -- Run all benchmarks
    defaultMain
      [ Send.benchmarks pool config,
        Read.benchmarks pool config,
        Ack.benchmarks pool config,
        Fifo.benchmarks pool config,
        MultiQueue.benchmarks pool config,
        Throughput.benchmarks pool config,
        Concurrent.benchmarks pool config,
        Raw.benchmarks pool config
      ]
