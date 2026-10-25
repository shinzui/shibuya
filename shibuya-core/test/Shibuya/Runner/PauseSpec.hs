module Shibuya.Runner.PauseSpec (spec) where

import Control.Concurrent (myThreadId, yield)
import Control.Concurrent.NQE.Process (newBoundedInbox)
import Control.Concurrent.NQE.Supervisor (Strategy (IgnoreAll))
import Control.Concurrent.STM
import Control.Monad (forM_, replicateM_, void)
import Data.Map.Strict qualified as Map
import Data.Time.Clock (getCurrentTime)
import Effectful (liftIO, runEff)
import Effectful.State.Static.Local qualified as State
import Shibuya qualified as Public
import Shibuya.Adapter (Adapter (..))
import Shibuya.Batch (BatchConfig (..), ackAllOk, defaultBatchConfig)
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Internal.Runner.Ingester (runIngesterWithMetrics)
import Shibuya.Internal.Runner.Master
import Shibuya.Internal.Runner.Pause
import Shibuya.Internal.Runner.Supervised (SupervisedProcessor (..), runSupervised)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import UnliftIO qualified as UIO

spec :: Spec
spec = describe "pause and resume" $ do
  it "preserves source-local effects and counts only yielded messages across skipped steps" $ do
    owner <- myThreadId
    now <- getCurrentTime
    h <- newMetricsHandle now
    pause <- newPauseHandle
    inbox <- newBoundedInbox 10
    updates <- runEff $ State.execState (0 :: Int) $ runTracingNoop $ do
      let numbers =
            Stream.unfoldrM
              ( \n -> do
                  liftIO $ myThreadId >>= (`shouldBe` owner)
                  State.modify @Int (+ 1)
                  pure $ if n < 6 then Just (n, n + 1) else Nothing
              )
              (0 :: Int)
          source =
            fmap
              (\n -> mkIngested (mkEnvelope (MessageId "source-local") n) (AckHandle (\_ -> pure ())))
              (Stream.filter even numbers)
      runIngesterWithMetrics (ProcessorId "source-local") h pause source inbox
    updates `shouldBe` 7
    snapshot <- sampleMetrics h
    snapshot.stats.received `shouldBe` 3

  it "requests nothing further when paused before source admission" $ do
    now <- getCurrentTime
    h <- newMetricsHandle now
    pause <- newPauseHandle
    requestPause pause `shouldReturn` True
    polled <- newEmptyTMVarIO
    inbox <- newBoundedInbox 10
    let action =
          runEff $
            runTracingNoop $
              runIngesterWithMetrics
                (ProcessorId "pause-ingester")
                h
                pause
                (Stream.repeatM (liftIO (atomically $ putTMVar polled ()) >> pure (mkIngested (mkEnvelope (MessageId "a") ()) (AckHandle (\_ -> pure ())))))
                inbox
    UIO.withAsync action $ \_ -> do
      UIO.timeout 100_000 (atomically $ takeTMVar polled) `shouldReturn` Nothing
      requestResume pause `shouldReturn` True
      UIO.timeout 1_000_000 (atomically $ takeTMVar polled) `shouldReturn` Just ()

  it "allows an admitted poll and in-flight work to drain, isolates siblings, and resumes before shutdown" $ do
    forM_ [False, True] $ \batching -> do
      polls <- newTQueueIO
      releases <- newTQueueIO
      starts <- newTQueueIO
      finishes <- newTVarIO (0 :: Int)
      stop <- newTVarIO False
      handlerGate <- newEmptyTMVarIO
      sibling <- newEmptyTMVarIO
      runEff $ runTracingNoop $ do
        let source =
              Stream.unfoldrM
                ( \n -> do
                    liftIO $ atomically $ writeTQueue polls n
                    next <-
                      liftIO $
                        atomically $
                          (readTVar stop >>= check >> pure Nothing) `orElse` (Just <$> readTQueue releases)
                    pure $ fmap (\() -> (mkIngested (mkEnvelope (MessageId "live") ()) (AckHandle (\_ -> liftIO $ atomically $ modifyTVar' finishes (+ 1))), n + 1)) next
                )
                (1 :: Int)
            adapter = Adapter "live" source (liftIO $ atomically $ writeTVar stop True)
            work = liftIO ((atomically (writeTQueue starts ()) >> atomically (takeTMVar handlerGate))) >> pure AckOk
            processor =
              if batching
                then Public.mkBatchProcessor adapter (\_ _ -> work >> pure ackAllOk) defaultBatchConfig {batchSize = 1}
                else Public.mkProcessor adapter (\_ -> work)
            siblingAdapter = Adapter "sibling" (Stream.fromList [mkIngested (mkEnvelope (MessageId "sibling") ()) (AckHandle (\_ -> pure ()))]) (pure ())
        result <- Public.runApp Public.defaultAppConfig [(ProcessorId "live", processor), (ProcessorId "sibling", Public.mkProcessor siblingAdapter (\_ -> liftIO (atomically $ putTMVar sibling ()) >> pure AckOk))]
        app <- either (liftIO . ioError . userError . show) pure result
        liftIO $ atomically (readTQueue polls) `shouldReturn` 1
        first <- Public.pauseProcessor app (ProcessorId "live")
        liftIO $ first `shouldSatisfy` isAppliedPause
        second <- Public.pauseProcessor app (ProcessorId "live")
        liftIO $ case (first, second) of
          (ControlApplied state, ControlAlreadyInState same) -> same `shouldBe` state
          other -> expectationFailure (show other)
        liftIO $ atomically $ writeTQueue releases ()
        liftIO $ bounded (atomically $ readTQueue starts) >> bounded (atomically $ takeTMVar sibling)
        during <- Public.getAppMetrics app
        liftIO $ (during Map.! ProcessorId "live").state `shouldSatisfy` pausedWith 1
        liftIO $ atomically $ putTMVar handlerGate ()
        liftIO $ bounded $ atomically $ readTVar finishes >>= check . (== 1)
        -- Completion includes the metrics decrement, which follows finalization.
        liftIO $
          bounded $
            let await = do
                  m <- getProcessorMetricsIO (Public.getAppMaster app) (ProcessorId "live")
                  if maybe False (pausedWith 0 . (.state)) m then pure () else yield >> await
             in await
        liftIO $ UIO.timeout 100_000 (atomically $ readTQueue polls) `shouldReturn` Nothing
        Public.resumeProcessor app (ProcessorId "live") >>= liftIO . (`shouldBe` ControlApplied IntakeRunning)
        Public.resumeProcessor app (ProcessorId "live") >>= liftIO . (`shouldBe` ControlAlreadyInState IntakeRunning)
        liftIO $ atomically (readTQueue polls) `shouldReturn` 2
        _ <- Public.pauseProcessor app (ProcessorId "live")
        drained <- Public.stopAppGracefully Public.defaultShutdownConfig app
        liftIO $ drained `shouldBe` True
        liftIO $ readTVarIO stop `shouldReturn` True

  it "reports unknown, uncontrollable, terminal and draining outcomes atomically" $ do
    master <- runEff $ startMaster IgnoreAll
    UIO.finally
      ( do
          now <- getCurrentTime
          h <- newMetricsHandle now
          pause <- newPauseHandle
          pauseProcessorIO master (ProcessorId "unknown") `shouldReturn` ControlNotFound
          runEff $ registerProcessor master (ProcessorId "fixture") h
          pauseProcessorIO master (ProcessorId "fixture") `shouldReturn` ControlNotControllable
          runEff $ registerProcessorWithPause master (ProcessorId "live") h (Just pause)
          replicateM_ 20 $ do
            UIO.mapConcurrently_ (\n -> void $ if even n then pauseProcessorIO master (ProcessorId "live") else resumeProcessorIO master (ProcessorId "live")) [1 .. 20 :: Int]
            intended <- isPaused pause
            sampled <- sampleMetrics h
            isJustPause sampled.state `shouldBe` intended
          _ <- UIO.concurrently (runEff $ drainAndResume master) (pauseProcessorIO master (ProcessorId "live"))
          isPaused pause `shouldReturn` False
          pauseProcessorIO master (ProcessorId "live") `shouldReturn` ControlDraining
          isProcessorPausedIO master (ProcessorId "live") `shouldReturn` Nothing
          markProcessorStoppedIO master (ProcessorId "live")
          resumeProcessorIO master (ProcessorId "live") `shouldReturn` ControlTerminal
          runEff $ unregisterProcessor master (ProcessorId "live")
          pauseProcessorIO master (ProcessorId "live") `shouldReturn` ControlTerminal
      )
      (runEff $ stopMaster master)

  it "keeps terminal halt and finalization failure above pause intent" $ do
    forM_ [False, True] $ \failure -> do
      started <- newEmptyTMVarIO
      release <- newEmptyTMVarIO
      master <- runEff $ startMaster IgnoreAll
      UIO.finally
        ( runEff $ runTracingNoop $ do
            let message = mkIngested (mkEnvelope (MessageId "terminal") ()) (AckHandle (\_ -> if failure then liftIO (ioError (userError "failure")) else pure ()))
                adapter = Adapter "terminal" (Stream.fromList [message]) (pure ())
            proc <-
              runSupervised
                master
                10
                (ProcessorId "terminal")
                Unordered
                Serial
                adapter
                ( \_ -> do
                    liftIO $ (atomically (putTMVar started ()) >> atomically (takeTMVar release))
                    pure $ if failure then AckOk else AckHalt (HaltFatal "stop")
                )
            liftIO $ bounded (atomically $ takeTMVar started)
            _ <- liftIO $ pauseProcessorIO master (ProcessorId "terminal")
            liftIO $ atomically $ putTMVar release ()
            liftIO $ bounded (atomically $ readTVar proc.done >>= check)
            liftIO $ resumeProcessorIO master (ProcessorId "terminal") `shouldReturn` ControlTerminal
            lifecycle <- liftIO $ getLifecycleSnapshotIO master
            liftIO $
              if failure
                then (lifecycle Map.! ProcessorId "terminal") `shouldSatisfy` (\case LifecycleFailed {} -> True; _ -> False)
                else (lifecycle Map.! ProcessorId "terminal") `shouldBe` LifecycleStopped
            m <- liftIO $ sampleMetrics proc.metrics
            liftIO $ m.state `shouldSatisfy` (\case Failed {} -> True; _ -> False)
        )
        (runEff $ stopMaster master)

isAppliedPause :: ControlOutcome -> Bool
isAppliedPause (ControlApplied (IntakePaused _)) = True
isAppliedPause _ = False

isJustPause :: ProcessorState -> Bool
isJustPause Paused {} = True
isJustPause _ = False

pausedWith :: Int -> ProcessorState -> Bool
pausedWith n (Paused info _ _) = info.inFlight == n
pausedWith _ _ = False

bounded :: IO a -> IO a
bounded action = UIO.timeout 2_000_000 action >>= maybe (expectationFailure "timed out" >> error "timeout") pure
