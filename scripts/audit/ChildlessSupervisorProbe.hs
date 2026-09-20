{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Diagnostic probe (not a release test). After EP-33 removed the idle master
-- loop, the NQE supervisor is still an async linked to the runApp caller. With
-- zero children it waits only on its own mailbox. This probe asks: if a FINITE
-- app completes, waitApp returns, the handle is dropped, and the calling thread
-- keeps running, does a later major GC kill the caller?
--
-- Modes:
--   drop    - finite app, waitApp, drop the handle, keep running (the question)
--   stop    - finite app, waitApp, stopApp, keep running          (control)
--   retain  - finite app, waitApp, keep handle alive past the GCs (control)
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, evaluate, try)
import Control.Monad (replicateM_)
import Data.IORef (newIORef, readIORef, writeIORef)
import Effectful (liftIO, runEff)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( AppConfig (..),
    ProcessorId (..),
    SupervisionStrategy (..),
    defaultAppConfig,
    mkProcessor,
    runApp,
    stopApp,
    waitApp,
  )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Environment (getArgs)
import System.Exit (die)
import System.Mem (performMajorGC)

main :: IO ()
main = do
  [mode, strategyName] <- getArgs
  strat <- case strategyName of
    "ignore" -> pure IgnoreFailures
    "stopall" -> pure StopAllOnFailure
    _ -> die "strategy: ignore|stopall"
  keep <- newIORef (pure () :: IO ())
  outcome <- try @SomeException $ do
    runEff $ runTracingNoop $ do
      let adapter =
            Adapter
              { adapterName = "probe:finite",
                source = Stream.nil,
                shutdown = pure ()
              }
      result <-
        runApp
          defaultAppConfig {strategy = strat}
          [(ProcessorId "finite", mkProcessor adapter (\_ -> pure AckOk))]
      case result of
        Left err -> liftIO $ die ("runApp failed: " <> show err)
        Right app -> do
          waitApp app
          case mode of
            "drop" -> pure ()
            "stop" -> stopApp app
            "retain" -> liftIO $ writeIORef keep (runEff (runTracingNoop (stopApp app)))
            _ -> liftIO $ die "mode: drop|stop|retain"
    putStrLn "waitApp returned; caller thread keeps running"
    replicateM_ 5 $ do
      threadDelay 100_000
      performMajorGC
    threadDelay 200_000
    -- Use the retained closure only after the observation window.
    readIORef keep >>= evaluate >>= id
  case outcome of
    Left err -> putStrLn ("RESULT " <> mode <> "/" <> strategyName <> ": CALLER KILLED: " <> displayException err)
    Right () -> putStrLn ("RESULT " <> mode <> "/" <> strategyName <> ": caller survived")
