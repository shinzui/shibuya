{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}

-- Diagnostic observations, not assertions of desired behavior.
-- Compile against the local library with cabal exec -- ghc -threaded -O1
-- -XGHC2024 -package shibuya-core scripts/audit/LifecycleProbe.hs.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar
import Control.Monad (forM_)
import Data.IORef
import Effectful
import Shibuya.Adapter
import Shibuya.App
import Shibuya.Batch
import Shibuya.Core.Ack
import Shibuya.Core.AckHandle
import Shibuya.Core.Ingested
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types
import Shibuya.Internal.Runner.KeyedScheduler
import Shibuya.Internal.Runner.Master (stopMaster)
import Shibuya.Policy
import Shibuya.Telemetry.Effect
import Streamly.Data.Stream qualified as Stream
import UnliftIO qualified as U

message :: Ingested es ()
message = mkIngested (mkEnvelope (MessageId "probe") ()) (AckHandle (const (pure ())))

idle :: (IOE :> es) => Eff es () -> Adapter es ()
idle close = Adapter "idle" (Stream.repeatM (liftIO (threadDelay 10000000) >> pure message)) close

requireApp :: (IOE :> es) => Either AppError a -> Eff es a
requireApp = either (U.throwIO . userError . show) pure

main :: IO ()
main = do
  duplicate <- runEff $ runTracingNoop $ do
    closed <- liftIO $ newIORef False
    let first = mkProcessor (idle (liftIO $ writeIORef closed True)) (const $ pure AckOk)
        lastOne = mkProcessor (Adapter "empty" (Stream.fromList []) (pure ())) (const $ pure AckOk)
    app <- runApp defaultAppConfig [(ProcessorId "duplicate", first), (ProcessorId "duplicate", lastOne)] >>= requireApp
    completed <- U.timeout 300000 (waitApp app)
    drained <- stopAppGracefully (ShutdownConfig 0.1) app
    signalled <- liftIO $ readIORef closed
    pure (completed, drained, signalled)
  putStrLn $ "duplicate (wait, drained, first shutdown called): " <> show duplicate

  shutdownResult <- runEff $ runTracingNoop $ do
    secondClosed <- liftIO $ newIORef False
    let first = mkProcessor (idle (U.throwIO $ userError "shutdown failed")) (const $ pure AckOk)
        second = mkProcessor (idle (liftIO $ writeIORef secondClosed True)) (const $ pure AckOk)
    app <- runApp defaultAppConfig [(ProcessorId "a", first), (ProcessorId "b", second)] >>= requireApp
    result <- U.tryAny (stopAppGracefully (ShutdownConfig 0.1) app)
    completed <- U.timeout 100000 (waitApp app)
    signalled <- liftIO $ readIORef secondClosed
    stopMaster (getAppMaster app)
    pure (either (const True) (const False) result, completed, signalled)
  putStrLn $ "shutdown (threw, wait, second shutdown called): " <> show shutdownResult

  halted <- runEff $ runTracingNoop $ do
    sourceWaiting <- liftIO newEmptyMVar
    handlerDone <- liftIO newEmptyMVar
    let step False = pure (Just (message, True))
        step True = do
          liftIO $ putMVar sourceWaiting ()
          liftIO $ threadDelay 10000000
          pure Nothing
        adapter = Adapter "one-then-idle" (Stream.unfoldrM step False) (pure ())
        handler _ _ = do
          liftIO $ readMVar sourceWaiting
          liftIO $ threadDelay 100000
          liftIO $ putMVar handlerDone ()
          pure $ ackAll (AckHalt (HaltFatal "probe"))
        processor = mkBatchProcessor adapter handler (defaultBatchConfig {batchSize = 1, batchTimeout = 0.01})
    app <- runApp defaultAppConfig [(ProcessorId "batch", processor)] >>= requireApp
    reached <- U.timeout 1000000 (liftIO $ readMVar handlerDone)
    completed <- U.timeout 300000 (waitApp app)
    stopMaster (getAppMaster app)
    pure (reached, completed)
  putStrLn $ "batch halt (handler reached, wait): " <> show halted

  forM_ [(Unordered, Serial), (Unordered, Async 2), (Unordered, Ahead 2), (PartitionedInOrder, Async 2)] $ \(ordering, concurrency) -> do
    outcome <- runEff $ runTracingNoop $ do
      waiting <- liftIO newEmptyMVar
      acked <- liftIO newEmptyMVar
      let item = mkIngested (mkEnvelope (MessageId "halt") ()) (AckHandle (const (liftIO $ putMVar acked ())))
          step False = pure (Just (item, True))
          step True = liftIO (putMVar waiting () >> threadDelay 10000000) >> pure Nothing
          adapter = Adapter "halt-control" (Stream.unfoldrM step False) (pure ())
          handler _ = liftIO (readMVar waiting >> threadDelay 100000) >> pure (AckHalt (HaltFatal "probe"))
      app <- runApp defaultAppConfig [(ProcessorId "halt", QueueProcessor adapter handler ordering concurrency)] >>= requireApp
      finalized <- U.timeout 1000000 (liftIO $ readMVar acked)
      completed <- U.timeout 300000 (waitApp app)
      stopMaster (getAppMaster app)
      pure (finalized, completed)
    putStrLn $ "single halt " <> show (ordering, concurrency) <> " (finalized, wait): " <> show outcome

  exhausted <- runEff $ runTracingNoop $ do
    attempts <- liftIO $ newIORef (0 :: Int)
    let item = mkIngested (mkEnvelope (MessageId "finalize-failure") ()) $ AckHandle $ \_ -> do
          liftIO $ modifyIORef' attempts (+ 1)
          U.throwIO $ userError "finalizer failed"
        adapter = Adapter "finalize-failure" (Stream.fromList [item]) (pure ())
    app <- runApp (defaultAppConfig {strategy = StopAllOnFailure}) [(ProcessorId "failure", mkProcessor adapter (const $ pure AckOk))] >>= requireApp
    result <- U.tryAny $ U.timeout 2000000 (waitApp app)
    n <- liftIO $ readIORef attempts
    stopMaster (getAppMaster app)
    pure (result, n)
  putStrLn $ "finalizer exhaustion StopAllOnFailure (wait result, attempts): " <> show exhausted

  count <- newIORef (0 :: Int)
  let input = Stream.unfoldrM (\n -> threadDelay 1000 >> pure (Just (n, n + 1))) (0 :: Int)
      worker 0 = U.throwIO $ userError "worker failed"
      worker _ = modifyIORef' count (+ 1)
  scheduler <- U.tryAny $ U.timeout 300000 $ runKeyedScheduler 1 2 (const (Nothing :: Maybe Int)) worker input
  processed <- readIORef count
  putStrLn $ "scheduler (outcome, processed after failure): " <> show (scheduler, processed)

  forM_ [-1, 0, 1, 2] $ \limit -> do
    outcome <- runEff $ runTracingNoop $ do
      counters <- liftIO $ newIORef (0 :: Int, 0 :: Int)
      let adapter = Adapter "policy" (Stream.fromList (replicate 20 message)) (pure ())
          handler _ = do
            liftIO $ atomicModifyIORef' counters $ \(active, peak) -> ((active + 1, max peak (active + 1)), ())
            liftIO $ threadDelay 50000
            liftIO $ atomicModifyIORef' counters $ \(active, peak) -> ((active - 1, peak), ())
            pure AckOk
      app <- runApp defaultAppConfig [(ProcessorId "policy", QueueProcessor adapter handler Unordered (Async limit))] >>= requireApp
      completed <- U.timeout 2000000 (waitApp app)
      stopMaster (getAppMaster app)
      peak <- liftIO $ snd <$> readIORef counters
      pure (completed, peak)
    putStrLn $ "Async " <> show limit <> " (wait, peak handlers): " <> show outcome
