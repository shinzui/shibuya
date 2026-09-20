{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent.STM
import MessageDb.Message qualified as Mdb
import Shibuya.Adapter.MessageDb.Internal.InflightState

main :: IO ()
main = do
  state <- newInflightState 4 (Mdb.GlobalPosition 0)
  atomically $ do
    recordIngested state (Mdb.GlobalPosition 2)
    recordAckResult state (Mdb.GlobalPosition 2) AckComplete
  advanced <- atomically $ advanceCheckpointTo state
  putStrLn $ "fully acknowledged category beginning at global position 2: " <> show advanced
  dense <- newInflightState 4 (Mdb.GlobalPosition 0)
  atomically $ do
    recordIngested dense (Mdb.GlobalPosition 1)
    recordAckResult dense (Mdb.GlobalPosition 1) AckComplete
  first <- atomically $ advanceCheckpointTo dense
  -- Model a caller whose storeCheckpoint fails after this first claim.
  second <- atomically $ advanceCheckpointTo dense
  putStrLn $ "checkpoint claims before/after an unpersisted claim: " <> show (first, second)
