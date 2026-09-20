{-# LANGUAGE OverloadedStrings #-}

-- This probe owns its process: retaining an AppHandle for cleanup would hide
-- the bug, and a weak pointer cannot guarantee cleanup after collection.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (replicateM_)
import Effectful (liftIO, runEff)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( AppConfig (..),
    ProcessorId (..),
    SupervisionStrategy (..),
    defaultAppConfig,
    mkProcessor,
    runApp,
    waitApp,
  )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Exit (die)
import System.Mem (performMajorGC)
import UnliftIO qualified as UIO

main :: IO ()
main = do
  started <- newEmptyMVar
  outcome <- try @SomeException $ UIO.timeout 5_000_000 $ UIO.race (gcWindow started) (worker started)
  case outcome of
    Left err -> die ("FAIL: bare waitApp died: " <> displayException err)
    Right Nothing -> die "FAIL: the GC observation window did not finish within five seconds"
    Right (Just (Right ())) -> die "FAIL: waitApp returned while the idle processor should still be running"
    Right (Just (Left ())) -> putStrLn "PASS: bare waitApp survives major collections"

gcWindow :: MVar () -> IO ()
gcWindow started = do
  -- Do not let a slow startup pass without exercising a running application.
  takeMVar started
  replicateM_ 5 $ do
    threadDelay 100_000
    performMajorGC
  -- Leave time for a linked exception from the last collection to arrive.
  threadDelay 200_000

worker :: MVar () -> IO ()
worker started = runEff $ runTracingNoop $ do
  -- A timer keeps the ingester alive just as a real adapter's poll delay does.
  -- An unreachable STM retry here would introduce a separate deadlock.
  let adapter =
        Adapter
          { adapterName = "gc-regression:idle",
            source = Stream.fromEffect $ liftIO $ do
              threadDelay 60_000_000
              fail "the idle adapter unexpectedly woke during the GC probe",
            shutdown = pure ()
          }
  result <-
    runApp
      defaultAppConfig {strategy = IgnoreFailures}
      [(ProcessorId "idle", mkProcessor adapter (\_ -> pure AckOk))]
  case result of
    Left err -> liftIO $ die ("runApp failed: " <> show err)
    Right app -> do
      liftIO $ putMVar started ()
      -- Deliberately no metrics server, retained handle, or subsequent stopApp.
      waitApp app
