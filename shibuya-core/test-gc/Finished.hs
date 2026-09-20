{-# LANGUAGE OverloadedStrings #-}

-- This probe owns its process for the same reason as Main.hs: retaining an
-- AppHandle for cleanup would hide the bug. It covers the state Main.hs cannot:
-- an application whose processors have all finished, so the supervisor has no
-- children, while the thread that called runApp keeps running.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (displayException, throwIO)
import Control.Monad (forM, replicateM_, unless)
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
import System.Exit (die, exitFailure)
import System.Mem (performMajorGC)
import UnliftIO qualified as UIO

main :: IO ()
main = do
  results <- forM scenarios $ \(name, strat, sourceFails) -> do
    -- Each scenario gets its own thread: the supervisor links to whichever
    -- thread calls runApp, and that is the thread a regression kills.
    outcome <- UIO.timeout 10_000_000 $ UIO.withAsync (caller strat sourceFails) UIO.waitCatch
    case outcome of
      Nothing -> False <$ putStrLn ("FAIL [" <> name <> "]: the observation did not finish within ten seconds")
      Just (Left err) -> False <$ putStrLn ("FAIL [" <> name <> "]: caller died after its application finished: " <> displayException err)
      Just (Right ()) -> True <$ putStrLn ("PASS [" <> name <> "]: caller survives major collections after its application finished")
  unless (and results) exitFailure
  where
    scenarios =
      [ ("finite source, IgnoreFailures", IgnoreFailures, False),
        ("finite source, StopAllOnFailure", StopAllOnFailure, False),
        ("failed source, IgnoreFailures", IgnoreFailures, True)
      ]

caller :: SupervisionStrategy -> Bool -> IO ()
caller strat sourceFails = do
  runEff $ runTracingNoop $ do
    let adapter =
          Adapter
            { adapterName = "gc-regression:finished",
              source =
                if sourceFails
                  then Stream.fromEffect (liftIO (throwIO (userError "the source failed on purpose")))
                  else Stream.nil,
              shutdown = pure ()
            }
    result <-
      runApp
        defaultAppConfig {strategy = strat}
        [(ProcessorId "finished", mkProcessor adapter (\_ -> pure AckOk))]
    case result of
      Left err -> liftIO $ die ("runApp failed: " <> show err)
      Right app -> waitApp app
  -- The handle is now out of scope. Deliberately no stopApp and no retained
  -- reference: every processor has finished and this thread simply carries on.
  replicateM_ 5 $ do
    threadDelay 100_000
    performMajorGC
  -- Leave time for a linked exception from the last collection to arrive.
  threadDelay 200_000
