-- | EP-29 — production-safety proof.
--
-- Drives the *production* runner 'runSupervised' under a real Master exactly the
-- way a live consumer does (no tasty), under sustained and cold-start load
-- across Serial / Ahead / Async concurrency with real bounded-inbox
-- backpressure. A global uncaught-exception handler catches a nested
-- @atomically@ raised on ANY thread (supervised children included), so if the
-- concurrent ingester/processor path can ever nest in production, this trips it.
--
-- Usage: prod-stress [rounds] [processorsPerRound] [messagesPerProcessor]
module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.Concurrent.STM (atomically, readTVar, retry)
import Control.DeepSeq (NFData)
import Control.Monad (forM, forM_, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import GHC.Conc.Sync (setUncaughtExceptionHandler)
import GHC.Generics (Generic)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested, mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..), mkEnvelope)
import Shibuya.Handler (Handler)
import Shibuya.Internal.Runner.Master (startMaster, stopMaster)
import Shibuya.Internal.Runner.Supervised (SupervisedProcessor (..), runSupervised)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Environment (getArgs)
import System.IO (hFlush, hPutStrLn, stderr, stdout)
import System.IO.Unsafe (unsafePerformIO)

data BenchMessage = BenchMessage {msgId :: !Int, msgPayload :: !Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

-- | Global tally of nested-atomically crashes seen on ANY thread.
{-# NOINLINE nestedRef #-}
nestedRef :: IORef Int
nestedRef = unsafePerformIO (newIORef 0)

main :: IO ()
main = do
  args <- getArgs
  let rounds = case args of (r : _) -> read r; _ -> 200
      procs = case args of (_ : p : _) -> read p; _ -> 8
      msgs = case args of (_ : _ : m : _) -> read m; _ -> 2000
  -- Catch a nested `atomically` (or anything) thrown on ANY thread, incl.
  -- supervised children, and record it globally.
  setUncaughtExceptionHandler $ \e -> do
    let s = show e
    when ("atomically was nested" `Text.isInfixOf` Text.pack s) $
      atomicModifyIORef' nestedRef (\n -> (n + 1, ()))
    hPutStrLn stderr $ "[uncaught on some thread] " <> s
  putStrLn $
    "prod-stress: "
      <> show rounds
      <> " rounds x "
      <> show procs
      <> " processors x "
      <> show msgs
      <> " msgs, across Serial/Ahead/Async"
  hFlush stdout
  total <- newIORef (0 :: Int)
  forM_ [1 .. rounds] $ \r -> do
    let mode = case r `mod` 3 of
          0 -> Serial
          1 -> Ahead 4
          _ -> Async 4
    processed <- runRound mode procs msgs
    atomicModifyIORef' total (\t -> (t + processed, ()))
    when (r `mod` 25 == 0) $ do
      n <- readIORef nestedRef
      t <- readIORef total
      putStrLn $ "  round " <> show r <> ": processed=" <> show t <> " nested-atomically=" <> show n
      hFlush stdout
  n <- readIORef nestedRef
  t <- readIORef total
  putStrLn $ "DONE. total processed=" <> show t <> "   nested-atomically crashes (any thread)=" <> show n
  putStrLn $
    if n > 0
      then "PRODUCTION IS AFFECTED (nested atomically occurred in runSupervised path)"
      else "no nested atomically in production path across this run"

-- | One round: start a Master, run @procs@ supervised processors concurrently,
-- each streaming @msgs@ messages through a small (backpressured) inbox, wait for
-- all to finish, stop the Master.
runRound :: Concurrency -> Int -> Int -> IO Int
runRound mode procs msgs = do
  counter <- newIORef (0 :: Int)
  runEff $ runTracingNoop $ do
    master <- startMaster IgnoreAll
    sps <- forM [1 .. procs] $ \i -> do
      ms <- createIngestedMessages msgs
      let adapter =
            Adapter
              { adapterName = "stress:" <> Text.pack (show i),
                source = Stream.fromList ms,
                shutdown = pure ()
              }
          -- Small inbox relative to message count => real backpressure, the
          -- concurrent ingester/processor race this bug lives in.
          inboxSize = 16
      runSupervised master inboxSize (ProcessorId (Text.pack ("p" <> show i))) Unordered mode adapter (countingHandler counter)
    -- Wait until every processor signals done (bounded by a hard wall clock).
    liftIO $ waitAllDone sps
    stopMaster master
  readIORef counter

waitAllDone :: [SupervisedProcessor] -> IO ()
waitAllDone sps = go (0 :: Int)
  where
    go n
      | n > 200000 = hPutStrLn stderr "  [warn] round wait timed out"
      | otherwise = do
          allDone <-
            atomically $
              let loop [] = pure True
                  loop (sp : rest) = do
                    d <- readTVar sp.done
                    if d then loop rest else pure False
               in loop sps
          if allDone then pure () else threadDelay 50 >> go (n + 1)

countingHandler :: (IOE :> es) => IORef Int -> Handler es BenchMessage
countingHandler counter _ = do
  _ <- liftIO $ atomicModifyIORef' counter (\c -> (c + 1, ()))
  pure AckOk

benchTime :: UTCTime
benchTime = UTCTime (fromGregorian 2024 1 1) 0

createIngestedMessages :: (IOE :> es) => Int -> Eff es [Ingested es BenchMessage]
createIngestedMessages n = mapM createMessage [1 .. n]
  where
    createMessage i = do
      let msgId' = MessageId $ Text.pack $ show i
          envelope = (mkEnvelope msgId' (BenchMessage i (Text.pack $ "payload-" <> show i))) {enqueuedAt = Just benchTime}
          ackHandle = AckHandle $ \_ -> pure ()
      pure $ mkIngested envelope ackHandle
