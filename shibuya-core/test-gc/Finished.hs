{-# LANGUAGE OverloadedStrings #-}

-- This probe owns its process for the same reason as Main.hs: retaining an
-- AppHandle for cleanup would hide the bug. It covers the state Main.hs cannot:
-- an application whose processors have all finished, so the supervisor has no
-- children, while the thread that called runApp keeps running.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (IgnoreAll), supervisor)
import Control.Exception (displayException, throwIO)
import Control.Monad (forM, replicateM_, unless, void)
import Data.List (isInfixOf)
import Effectful (IOE, liftIO, runEff)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( AppConfig (..),
    ProcessorId (..),
    QueueProcessor (..),
    SupervisionStrategy (..),
    defaultAppConfig,
    mkBatchProcessor,
    mkProcessor,
    runApp,
    waitApp,
  )
import Shibuya.Batch (BatchConfig (..), ackAll, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested, mkIngested)
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Exit (die, exitFailure)
import System.Mem (performMajorGC)
import UnliftIO qualified as UIO

type Processors = [(ProcessorId, QueueProcessor '[Tracing, IOE])]

main :: IO ()
main = do
  survived <- forM scenarios $ \(name, strat, processors) -> do
    -- Each scenario gets its own thread: a linked supervisor targets whichever
    -- thread calls runApp, and that is the thread a regression kills.
    outcome <- observe (finishThenKeepRunning strat processors)
    case outcome of
      Nothing -> False <$ putStrLn ("FAIL [" <> name <> "]: the observation did not finish within ten seconds")
      Just (Left err) -> False <$ putStrLn ("FAIL [" <> name <> "]: caller died after its application finished: " <> displayException err)
      Just (Right ()) -> True <$ putStrLn ("PASS [" <> name <> "]: caller survives major collections after its application finished")
  detectable <- control
  unless (and survived && detectable) exitFailure
  where
    observe action = UIO.timeout 10_000_000 $ UIO.withAsync action UIO.waitCatch

    -- The defect itself, rebuilt from NQE alone: a linked supervisor with no
    -- children whose handle is dropped. It MUST kill its caller. If it ever
    -- stops doing so, this build cannot detect the failure class at all and the
    -- PASS lines above prove nothing, so the suite fails rather than pass vacuously.
    control = do
      outcome <- observe $ do
        void (supervisor IgnoreAll)
        keepRunningThroughCollections
      case outcome of
        Just (Left err)
          | "blocked indefinitely" `isInfixOf` displayException err ->
              True <$ putStrLn "PASS [control]: a linked childless supervisor still kills its caller, so the scenarios above are meaningful"
        other -> False <$ putStrLn ("FAIL [control]: a linked childless supervisor no longer kills its caller (" <> maybe "timed out" (either displayException (const "survived")) other <> "); re-establish a reproducer before trusting this suite")

scenarios :: [(String, SupervisionStrategy, Processors)]
scenarios =
  [ ("finite source, IgnoreFailures", IgnoreFailures, [(ProcessorId "finished", mkProcessor (finite 0) ok)]),
    ("finite source, StopAllOnFailure", StopAllOnFailure, [(ProcessorId "finished", mkProcessor (finite 0) ok)]),
    ("failed source, IgnoreFailures", IgnoreFailures, [(ProcessorId "failed", mkProcessor failedSource ok)]),
    ("handler halt on a live idle source, IgnoreFailures", IgnoreFailures, [(ProcessorId "halted", mkProcessor oneThenIdle halt)]),
    ("handler halt on a live idle source, StopAllOnFailure", StopAllOnFailure, [(ProcessorId "halted", mkProcessor oneThenIdle halt)]),
    ( "serial, concurrent and batch processors together, StopAllOnFailure",
      StopAllOnFailure,
      [ (ProcessorId "serial", mkProcessor (finite 5) ok),
        (ProcessorId "concurrent", (mkProcessor (finite 50) ok) {ordering = Unordered, concurrency = Async 4}),
        (ProcessorId "batch", mkBatchProcessor (finite 7) (\_ _ -> pure (ackAll AckOk)) defaultBatchConfig {batchSize = 2, batchTimeout = 0.1})
      ]
    )
  ]
  where
    ok _ = pure AckOk
    halt _ = pure (AckHalt (HaltFatal "halt on purpose"))

-- | Run an application to its end on this thread, let the handle go out of
-- scope, and keep running. Deliberately no stopApp and no retained reference.
finishThenKeepRunning :: SupervisionStrategy -> Processors -> IO ()
finishThenKeepRunning strat processors = do
  runEff $ runTracingNoop $ do
    result <- runApp defaultAppConfig {strategy = strat, inboxSize = 10} processors
    case result of
      Left err -> liftIO $ die ("runApp failed: " <> show err)
      Right app -> waitApp app
  keepRunningThroughCollections

keepRunningThroughCollections :: IO ()
keepRunningThroughCollections = do
  replicateM_ 5 $ do
    threadDelay 100_000
    performMajorGC
  -- Leave time for a linked exception from the last collection to arrive.
  threadDelay 200_000

message :: Int -> Ingested '[Tracing, IOE] String
message n = mkIngested (mkEnvelope (MessageId "gc-regression") ("message-" <> show n)) (AckHandle $ \_ -> pure ())

finite :: Int -> Adapter '[Tracing, IOE] String
finite count =
  Adapter
    { adapterName = "gc-regression:finite",
      source = Stream.fromList (map message [1 .. count]),
      shutdown = pure ()
    }

failedSource :: Adapter '[Tracing, IOE] String
failedSource =
  Adapter
    { adapterName = "gc-regression:failed",
      source = Stream.fromEffect (liftIO (throwIO (userError "the source failed on purpose"))),
      shutdown = pure ()
    }

-- | One message, then a quiet queue: the source stays alive but produces nothing.
oneThenIdle :: Adapter '[Tracing, IOE] String
oneThenIdle =
  Adapter
    { adapterName = "gc-regression:one-then-idle",
      source = Stream.unfoldrM step (0 :: Int),
      shutdown = pure ()
    }
  where
    step 0 = pure (Just (message 0, 1))
    step _ = liftIO (threadDelay 60_000_000) >> pure Nothing
