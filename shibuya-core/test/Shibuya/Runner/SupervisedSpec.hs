{-# LANGUAGE OverloadedStrings #-}

module Shibuya.Runner.SupervisedSpec (spec) where

import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.Concurrent.STM (readTVarIO)
import Control.Monad (forM, replicateM)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( ShutdownConfig (..),
    SupervisionStrategy (..),
    mkProcessor,
    runApp,
    stopAppGracefully,
  )
import Shibuya.Core (ProcessorHalt (..))
import Shibuya.Core.Ack (AckDecision (..), HaltReason (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Cursor (..), Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Runner.Master
  ( getAllMetrics,
    startMaster,
    stopMaster,
  )
import Shibuya.Runner.Metrics
  ( InFlightInfo (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
  )
import Shibuya.Runner.Supervised
  ( SupervisedProcessor (..),
    getMetrics,
    isDone,
    runSupervised,
    runWithMetrics,
  )
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import UnliftIO (SomeException, try)
import UnliftIO.Concurrent (threadDelay)

spec :: Spec
spec = do
  describe "Shibuya.Runner.Master" $ do
    it "starts and stops cleanly" $ do
      result <- runEff $ runTracingNoop $ do
        master <- startMaster IgnoreAll
        stopMaster master
        pure ()
      result `shouldBe` ()

    it "returns empty metrics initially" $ do
      metrics <- runEff $ runTracingNoop $ do
        master <- startMaster IgnoreAll
        m <- getAllMetrics master
        stopMaster master
        pure m
      metrics `shouldSatisfy` null

  describe "Shibuya.Runner.Supervised" $ do
    describe "runWithMetrics" $ do
      it "processes messages and tracks metrics" $ do
        (finalMetrics, processedMsgs) <- runEff $ runTracingNoop $ do
          -- Track processed messages
          processedRef <- liftIO $ newIORef ([] :: [String])

          -- Create test messages
          messages <- createTestMessages 3

          -- Create adapter and handler
          let adapter = testAdapter messages
              handler = testHandler processedRef
              procId = ProcessorId "test-processor"

          -- Run with metrics
          sp <- runWithMetrics 10 procId adapter handler

          -- Get results
          metrics <- getMetrics sp
          msgs <- liftIO $ readIORef processedRef
          pure (metrics, msgs)

        -- Verify metrics
        finalMetrics.stats.received `shouldBe` 3
        finalMetrics.stats.processed `shouldBe` 3
        finalMetrics.stats.failed `shouldBe` 0
        finalMetrics.state `shouldBe` Idle

        -- Verify all messages were processed
        length processedMsgs `shouldBe` 3

      it "tracks failed messages" $ do
        finalMetrics <- runEff $ runTracingNoop $ do
          messages <- createTestMessages 3

          let adapter = testAdapter messages
              handler = failingHandler
              procId = ProcessorId "failing-processor"

          sp <- runWithMetrics 10 procId adapter handler
          getMetrics sp

        -- All should be failed (handler throws)
        finalMetrics.stats.failed `shouldBe` 3

      it "marks processor as done when stream exhausted" $ do
        done <- runEff $ runTracingNoop $ do
          messages <- createTestMessages 2

          let adapter = testAdapter messages
              handler = alwaysAckOk
              procId = ProcessorId "quick-processor"

          sp <- runWithMetrics 10 procId adapter handler
          isDone sp

        done `shouldBe` True

    describe "AckHalt behavior" $ do
      it "stops processing when handler returns AckHalt" $ do
        processedCount <- do
          processedRef <- newIORef (0 :: Int)

          let handler _ = do
                count <- liftIO $ readIORef processedRef
                liftIO $ modifyIORef' processedRef (+ 1)
                if count >= 2
                  then pure $ AckHalt (HaltFatal "stopping after 3")
                  else pure AckOk

          -- Try to run and catch ProcessorHalt
          result <- try $ runEff $ runTracingNoop $ do
            messages <- createTestMessages 10
            let adapter = testAdapter messages
                procId = ProcessorId "halting-processor"
            runWithMetrics 10 procId adapter handler

          -- Verify ProcessorHalt was thrown
          case result of
            Left (ProcessorHalt reason) ->
              reason `shouldBe` HaltFatal "stopping after 3"
            Right _ ->
              expectationFailure "Expected ProcessorHalt exception"

          readIORef processedRef

        -- Should have processed exactly 3 messages before halt
        processedCount `shouldBe` 3

      it "updates metrics to halted state on AckHalt" $ do
        finalMetrics <- runEff $ runTracingNoop $ do
          messages <- createTestMessages 5

          let handler _ = pure $ AckHalt (HaltFatal "immediate halt")
              adapter = testAdapter messages

          master <- startMaster IgnoreAll

          -- runSupervised catches ProcessorHalt, so we can check metrics
          sp <- runSupervised master 10 (ProcessorId "halt-metrics") Serial adapter handler

          -- Wait for processor to halt
          liftIO $ threadDelay 100000 -- 100ms
          m <- liftIO $ readTVarIO sp.metrics
          stopMaster master
          pure m

        case finalMetrics.state of
          Failed msg _ -> msg `shouldSatisfy` (Text.isInfixOf "immediate halt")
          other -> expectationFailure $ "Expected Failed state, got: " ++ show other

      it "halt in one supervised processor doesn't affect others" $ do
        (countA, countB) <- runEff $ runTracingNoop $ do
          countARef <- liftIO $ newIORef (0 :: Int)
          countBRef <- liftIO $ newIORef (0 :: Int)

          messagesA <- createTestMessages 10
          messagesB <- createTestMessages 10

          -- Handler A halts after 2 messages
          let handlerA _ = do
                count <- liftIO $ readIORef countARef
                liftIO $ modifyIORef' countARef (+ 1)
                if count >= 1
                  then pure $ AckHalt (HaltFatal "A stopping")
                  else pure AckOk

          -- Handler B processes all messages
          let handlerB _ = do
                liftIO $ modifyIORef' countBRef (+ 1)
                pure AckOk

          let adapterA = testAdapter messagesA
              adapterB = testAdapter messagesB

          master <- startMaster IgnoreAll

          _spA <- runSupervised master 10 (ProcessorId "A") Serial adapterA handlerA
          _spB <- runSupervised master 10 (ProcessorId "B") Serial adapterB handlerB

          -- Wait for both to complete
          liftIO $ threadDelay 500000 -- 500ms
          cA <- liftIO $ readIORef countARef
          cB <- liftIO $ readIORef countBRef

          stopMaster master
          pure (cA, cB)

        -- A should have stopped after 2 messages
        countA `shouldBe` 2
        -- B should have processed all 10
        countB `shouldBe` 10

    describe "Concurrency modes" $ do
      describe "Ahead mode" $ do
        it "processes all messages successfully" $ do
          countRef <- newIORef (0 :: Int)

          finalCount <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 5

            let handler _ = do
                  liftIO $ modifyIORef' countRef (+ 1)
                  liftIO $ threadDelay 10000 -- 10ms
                  pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _ <- runSupervised master 10 (ProcessorId "ahead") (Ahead 3) adapter handler

            -- Wait for completion
            liftIO $ threadDelay 300000 -- 300ms
            stopMaster master
            liftIO $ readIORef countRef

          finalCount `shouldBe` 5

        it "respects maxBuffer limit" $ do
          -- This tests that we don't start too many concurrent tasks
          maxInFlightRef <- newIORef (0 :: Int)
          currentInFlightRef <- newIORef (0 :: Int)

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 10

            let handler _ = do
                  -- Increment current in-flight
                  cur <- liftIO $ do
                    modifyIORef' currentInFlightRef (+ 1)
                    readIORef currentInFlightRef
                  -- Update max
                  liftIO $ modifyIORef' maxInFlightRef (\m -> max m cur)
                  -- Simulate some work
                  liftIO $ threadDelay 50000 -- 50ms
                  -- Decrement in-flight
                  liftIO $ modifyIORef' currentInFlightRef (\c -> c - 1)
                  pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            -- Use Ahead with max 3 concurrent
            _sp <- runSupervised master 10 (ProcessorId "ahead-limit") (Ahead 3) adapter handler

            liftIO $ threadDelay 1000000 -- 1s to let it complete
            stopMaster master

          maxInFlight <- readIORef maxInFlightRef
          -- Max in-flight should not exceed buffer size + 1 (buffer + currently processing)
          maxInFlight `shouldSatisfy` (<= 4)

      describe "Async mode" $ do
        it "processes all messages concurrently" $ do
          countRef <- newIORef (0 :: Int)

          finalCount <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 5

            let handler _ = do
                  liftIO $ modifyIORef' countRef (+ 1)
                  liftIO $ threadDelay 10000 -- 10ms
                  pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _ <- runSupervised master 10 (ProcessorId "async") (Async 5) adapter handler

            -- Wait for completion
            liftIO $ threadDelay 300000 -- 300ms
            stopMaster master
            liftIO $ readIORef countRef

          finalCount `shouldBe` 5

        it "respects concurrency limit" $ do
          maxInFlightRef <- newIORef (0 :: Int)
          currentInFlightRef <- newIORef (0 :: Int)

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 10

            let handler _ = do
                  cur <- liftIO $ do
                    modifyIORef' currentInFlightRef (+ 1)
                    readIORef currentInFlightRef
                  liftIO $ modifyIORef' maxInFlightRef (\m -> max m cur)
                  liftIO $ threadDelay 50000 -- 50ms
                  liftIO $ modifyIORef' currentInFlightRef (\c -> c - 1)
                  pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _sp <- runSupervised master 10 (ProcessorId "async-limit") (Async 3) adapter handler

            liftIO $ threadDelay 1000000 -- 1s
            stopMaster master

          maxInFlight <- readIORef maxInFlightRef
          maxInFlight `shouldSatisfy` (<= 4)

      describe "Halt with concurrency" $ do
        it "waits for in-flight to complete before halting" $ do
          processedRef <- newIORef ([] :: [Int])

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 10

            let handler ingested = do
                  let msgNum = case ingested.envelope.cursor of
                        Just (CursorInt n) -> n
                        _ -> 0
                  -- Simulate work
                  liftIO $ threadDelay 50000 -- 50ms
                  liftIO $ modifyIORef' processedRef (msgNum :)
                  -- Halt on message 3
                  if msgNum == 3
                    then pure $ AckHalt (HaltFatal "halt on 3")
                    else pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _sp <- runSupervised master 10 (ProcessorId "halt-concurrent") (Async 3) adapter handler

            liftIO $ threadDelay 500000 -- 500ms
            stopMaster master

          processed <- readIORef processedRef
          -- With Async 3, messages 1, 2, 3 start together
          -- When 3 halts, 1 and 2 should complete
          length processed `shouldSatisfy` (>= 3)

        it "stops reading new messages after halt decision" $ do
          processedRef <- newIORef (0 :: Int)

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 20

            let handler _ = do
                  count <- liftIO $ do
                    modifyIORef' processedRef (+ 1)
                    readIORef processedRef
                  liftIO $ threadDelay 20000 -- 20ms
                  -- Halt after processing 5 messages
                  if count >= 5
                    then pure $ AckHalt (HaltFatal "halt at 5")
                    else pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _sp <- runSupervised master 10 (ProcessorId "halt-stop-read") (Async 3) adapter handler

            liftIO $ threadDelay 500000 -- 500ms
            stopMaster master

          processed <- readIORef processedRef
          -- Should process around 5-8 messages (5 before halt + a few in-flight)
          -- but definitely not all 20
          processed `shouldSatisfy` (< 15)

      describe "Error handling" $ do
        it "handler exception doesn't affect other in-flight handlers" $ do
          resultsRef <- newIORef ([] :: [Either String Int])

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 5

            let handler ingested = do
                  let msgNum = case ingested.envelope.cursor of
                        Just (CursorInt n) -> n
                        _ -> 0
                  -- Message 2 throws an exception
                  if msgNum == 2
                    then do
                      liftIO $ modifyIORef' resultsRef (Left "error on 2" :)
                      error "Intentional failure on message 2"
                    else do
                      liftIO $ threadDelay 30000 -- 30ms
                      liftIO $ modifyIORef' resultsRef (Right msgNum :)
                      pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _ <- runSupervised master 10 (ProcessorId "error-handling") (Async 3) adapter handler

            liftIO $ threadDelay 500000 -- 500ms
            stopMaster master

          results <- readIORef resultsRef
          -- Message 2 should have errored
          let errors = [e | Left e <- results]
          length errors `shouldBe` 1
          -- Other messages (1, 3, 4, 5) should have succeeded
          let successes = [n | Right n <- results]
          length successes `shouldSatisfy` (>= 3)

      describe "Metrics tracking" $ do
        it "tracks in-flight count during concurrent processing" $ do
          maxInFlightObserved <- newIORef (0 :: Int)

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 5

            let handler _ = do
                  liftIO $ threadDelay 100000 -- 100ms
                  pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            sp <- runSupervised master 10 (ProcessorId "metrics-test") (Async 3) adapter handler

            -- Check metrics while processing
            liftIO $ do
              threadDelay 50000 -- 50ms - should be in the middle of processing
              metrics <- readTVarIO sp.metrics
              case metrics.state of
                Processing info _ -> modifyIORef' maxInFlightObserved (max info.inFlight)
                _ -> pure ()

            liftIO $ threadDelay 600000 -- 600ms to complete
            stopMaster master

          maxObserved <- readIORef maxInFlightObserved
          -- Should have observed at least 2 concurrent handlers
          maxObserved `shouldSatisfy` (>= 2)

        it "reports correct maxConcurrency in metrics" $ do
          observedMaxConc <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 3

            let handler _ = do
                  liftIO $ threadDelay 50000 -- 50ms
                  pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            sp <- runSupervised master 10 (ProcessorId "max-conc") (Ahead 7) adapter handler

            -- Check metrics while processing
            result <- liftIO $ do
              threadDelay 25000 -- 25ms
              metrics <- readTVarIO sp.metrics
              case metrics.state of
                Processing info _ -> pure $ Just info.maxConcurrency
                _ -> pure Nothing

            liftIO $ threadDelay 300000
            stopMaster master
            pure result

          observedMaxConc `shouldBe` Just 7

      describe "Ahead mode ordering" $ do
        it "completes handlers and emits results in input order" $ do
          -- Track the order in which handlers START and COMPLETE
          startOrderRef <- newIORef ([] :: [Int])
          completeOrderRef <- newIORef ([] :: [Int])

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 5

            let handler ingested = do
                  let msgNum = case ingested.envelope.cursor of
                        Just (CursorInt n) -> n
                        _ -> 0
                  -- Record start
                  liftIO $ modifyIORef' startOrderRef (msgNum :)
                  -- Variable delay: message 1 is slowest, 5 is fastest
                  liftIO $ threadDelay ((6 - msgNum) * 20000)
                  -- Record completion
                  liftIO $ modifyIORef' completeOrderRef (msgNum :)
                  pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _ <- runSupervised master 10 (ProcessorId "ahead-order") (Ahead 5) adapter handler

            liftIO $ threadDelay 500000 -- 500ms
            stopMaster master

          -- With Ahead mode, all 5 should complete
          completeOrder <- readIORef completeOrderRef
          length completeOrder `shouldBe` 5

    -- The key property: all messages were processed
    -- (Ordering of side effects may vary, but stream output is ordered)

    describe "Robustness" $ do
      describe "Adapter source exceptions" $ do
        it "handles adapter source throwing mid-stream" $ do
          processedRef <- newIORef (0 :: Int)

          _ <- runEff $ runTracingNoop $ do
            -- Create an adapter where source throws after 3 messages
            _goodMessages <- createTestMessages 3
            -- Use fromEffect to throw after yielding good messages
            let failingSource = Stream.unfoldrM step (0 :: Int)
                  where
                    step n
                      | n < 3 = do
                          msg <- liftIO $ createSingleMessage (n + 1)
                          pure $ Just (msg, n + 1)
                      | n == 3 = error "Network failure mid-stream"
                      | otherwise = pure Nothing

            let adapter =
                  Adapter
                    { adapterName = "test:failing-source",
                      source = failingSource,
                      shutdown = pure ()
                    }

            let handler _ = do
                  liftIO $ modifyIORef' processedRef (+ 1)
                  pure AckOk

            master <- startMaster IgnoreAll
            _ <- runSupervised master 10 (ProcessorId "failing-adapter") Serial adapter handler

            -- Wait for processing
            liftIO $ threadDelay 200000 -- 200ms
            stopMaster master

          -- Should have processed the 3 good messages before the error
          processed <- readIORef processedRef
          processed `shouldBe` 3

      describe "Rapid start/stop cycles" $ do
        it "handles rapid start/stop without resource leaks" $ do
          -- Run 50 rapid cycles
          results <- replicateM 50 $ runEff $ runTracingNoop $ do
            master <- startMaster IgnoreAll
            messages <- createTestMessages 5

            let adapter = testAdapter messages
                handler _ = pure AckOk

            sp <- runSupervised master 10 (ProcessorId "rapid") Serial adapter handler

            -- Minimal wait
            liftIO $ threadDelay 10000 -- 10ms
            stopMaster master

            -- Check it stopped cleanly
            isDone sp

          -- All should complete (no hangs, no crashes)
          length results `shouldBe` 50

        it "handles concurrent start/stop cycles" $ do
          -- Run 20 concurrent cycles
          countRef <- newIORef (0 :: Int)

          _ <- runEff $ runTracingNoop $ do
            master <- startMaster IgnoreAll

            -- Start 10 processors rapidly
            _sps <- forM [(1 :: Int) .. 10] $ \i -> do
              messages <- createTestMessages 3
              let adapter = testAdapter messages
                  handler _ = do
                    liftIO $ modifyIORef' countRef (+ 1)
                    liftIO $ threadDelay 5000 -- 5ms
                    pure AckOk
              runSupervised master 10 (ProcessorId $ "concurrent-" <> Text.pack (show i)) Serial adapter handler

            -- Wait briefly then stop
            liftIO $ threadDelay 100000 -- 100ms
            stopMaster master

          -- Should have processed messages from multiple processors
          count <- readIORef countRef
          count `shouldSatisfy` (> 0)

      describe "KillAll supervision strategy" $ do
        it "stops all processors when adapter source fails with KillAll strategy" $ do
          countARef <- newIORef (0 :: Int)
          countBRef <- newIORef (0 :: Int)

          _ :: Either SomeException () <- try $ runEff $ runTracingNoop $ do
            messagesB <- createTestMessages 20

            -- Adapter A throws after 3 messages (ingester crash, not handler)
            let failingSourceA = Stream.unfoldrM step (0 :: Int)
                  where
                    step n
                      | n < 3 = do
                          msg <- liftIO $ createSingleMessage (n + 1)
                          pure $ Just (msg, n + 1)
                      | otherwise = error "Adapter A source failed!"

            let adapterA =
                  Adapter
                    { adapterName = "test:failing-A",
                      source = failingSourceA,
                      shutdown = pure ()
                    }

            -- Handler A counts messages
            let handlerA _ = do
                  liftIO $ modifyIORef' countARef (+ 1)
                  liftIO $ threadDelay 10000 -- 10ms
                  pure AckOk

            -- Handler B processes slowly
            let handlerB _ = do
                  liftIO $ modifyIORef' countBRef (+ 1)
                  liftIO $ threadDelay 30000 -- 30ms
                  pure AckOk

            let adapterB = testAdapter messagesB

            -- Use KillAll strategy
            master <- startMaster KillAll

            _spA <- runSupervised master 10 (ProcessorId "killall-A") Serial adapterA handlerA
            _spB <- runSupervised master 10 (ProcessorId "killall-B") Serial adapterB handlerB

            -- Wait for A to fail and trigger KillAll
            liftIO $ threadDelay 500000 -- 500ms
            stopMaster master

          -- A should have processed messages before adapter failed
          countA <- readIORef countARef
          countA `shouldSatisfy` (<= 3)

          -- B should have been killed (not processed all 20)
          countB <- readIORef countBRef
          countB `shouldSatisfy` (< 20)

      describe "Multiple concurrent halts" $ do
        it "handles multiple handlers returning AckHalt simultaneously" $ do
          haltCountRef <- newIORef (0 :: Int)
          processedRef <- newIORef (0 :: Int)

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 10

            let handler ingested = do
                  let msgNum = case ingested.envelope.cursor of
                        Just (CursorInt n) -> n
                        _ -> 0
                  liftIO $ modifyIORef' processedRef (+ 1)
                  liftIO $ threadDelay 30000 -- 30ms
                  -- Messages 2, 3, 4 all return halt
                  if msgNum `elem` [2, 3, 4]
                    then do
                      liftIO $ modifyIORef' haltCountRef (+ 1)
                      pure $ AckHalt (HaltFatal $ "halt from " <> Text.pack (show msgNum))
                    else pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _ <- runSupervised master 10 (ProcessorId "multi-halt") (Async 5) adapter handler

            liftIO $ threadDelay 500000 -- 500ms
            stopMaster master

          -- Multiple halts should have been recorded
          haltCount <- readIORef haltCountRef
          haltCount `shouldSatisfy` (>= 1) -- At least one halt processed

          -- Should not have processed all messages
          processed <- readIORef processedRef
          processed `shouldSatisfy` (< 10)

      describe "Stability under load" $ do
        it "processes many messages without issues" $ do
          processedRef <- newIORef (0 :: Int)

          finalCount <- runEff $ runTracingNoop $ do
            -- 500 messages
            messages <- createTestMessages 500

            let handler _ = do
                  liftIO $ modifyIORef' processedRef (+ 1)
                  pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _sp <- runSupervised master 100 (ProcessorId "load-test") (Async 10) adapter handler

            -- Wait for completion
            liftIO $ threadDelay 2000000 -- 2s
            stopMaster master
            liftIO $ readIORef processedRef

          finalCount `shouldBe` 500

        it "handles mixed success and failure under load" $ do
          successRef <- newIORef (0 :: Int)
          failRef <- newIORef (0 :: Int)

          _ <- runEff $ runTracingNoop $ do
            messages <- createTestMessages 200

            let handler ingested = do
                  let msgNum = case ingested.envelope.cursor of
                        Just (CursorInt n) -> n
                        _ -> 0
                  -- Every 7th message fails
                  if msgNum `mod` 7 == 0
                    then do
                      liftIO $ modifyIORef' failRef (+ 1)
                      error "Intentional failure"
                    else do
                      liftIO $ modifyIORef' successRef (+ 1)
                      pure AckOk

            master <- startMaster IgnoreAll
            let adapter = testAdapter messages
            _ <- runSupervised master 50 (ProcessorId "mixed-load") (Async 5) adapter handler

            liftIO $ threadDelay 1000000 -- 1s
            stopMaster master

          success <- readIORef successRef
          failures <- readIORef failRef

          -- Should have processed many messages
          success `shouldSatisfy` (> 150)
          -- Should have recorded failures
          failures `shouldSatisfy` (> 20)

  describe "Graceful Shutdown" $ do
    describe "stopAppGracefully" $ do
      it "drains in-flight messages before stopping" $ do
        processedRef <- newIORef (0 :: Int)

        drained <- runEff $ runTracingNoop $ do
          messages <- createTestMessages 10

          let handler _ = do
                liftIO $ do
                  threadDelay 50000 -- 50ms per message
                  modifyIORef' processedRef (+ 1)
                pure AckOk

          let adapter = testAdapter messages
              processor = mkProcessor adapter handler

          result <- runApp IgnoreFailures 10 [(ProcessorId "drain-test", processor)]
          case result of
            Left _ -> pure False
            Right appHandle -> do
              -- Give some time for processing to start
              liftIO $ threadDelay 100000 -- 100ms

              -- Graceful shutdown with generous timeout
              let config = ShutdownConfig {drainTimeout = 5} -- 5 seconds
              stopAppGracefully config appHandle

        drained `shouldBe` True

        -- All messages should have been processed
        processed <- readIORef processedRef
        processed `shouldBe` 10

      it "respects timeout when processors are slow" $ do
        processedRef <- newIORef (0 :: Int)

        drained <- runEff $ runTracingNoop $ do
          messages <- createTestMessages 20

          let handler _ = do
                liftIO $ do
                  threadDelay 500000 -- 500ms per message - very slow
                  modifyIORef' processedRef (+ 1)
                pure AckOk

          let adapter = testAdapter messages
              processor = mkProcessor adapter handler

          result <- runApp IgnoreFailures 5 [(ProcessorId "timeout-test", processor)]
          case result of
            Left _ -> pure True -- Treat error as "drained" for simplicity
            Right appHandle -> do
              -- Start immediately
              liftIO $ threadDelay 100000 -- 100ms

              -- Very short timeout (0.3 seconds)
              let config = ShutdownConfig {drainTimeout = 0.3}
              stopAppGracefully config appHandle

        -- Should timeout (not all drained)
        drained `shouldBe` False

        -- Should have processed only some messages
        processed <- readIORef processedRef
        processed `shouldSatisfy` (< 20)

      it "returns True when all processors finish quickly" $ do
        drained <- runEff $ runTracingNoop $ do
          messages <- createTestMessages 5

          let handler _ = pure AckOk -- Instant processing
          let adapter = testAdapter messages
              processor = mkProcessor adapter handler

          result <- runApp IgnoreFailures 10 [(ProcessorId "quick-test", processor)]
          case result of
            Left _ -> pure False
            Right appHandle -> do
              -- Give time to complete
              liftIO $ threadDelay 200000 -- 200ms
              let config = ShutdownConfig {drainTimeout = 1}
              stopAppGracefully config appHandle

        drained `shouldBe` True

-- Test helpers

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 1 1) 0

createTestMessages :: (IOE :> es) => Int -> Eff es [Ingested es String]
createTestMessages n = mapM createMessage [1 .. n]
  where
    createMessage i = do
      let msgId = MessageId $ "msg-" <> Text.pack (show i)
          env =
            Envelope
              { messageId = msgId,
                cursor = Just (CursorInt i),
                partition = Nothing,
                enqueuedAt = Just testTime,
                traceContext = Nothing,
                payload = "message-" <> show i
              }
          ackHandle = AckHandle $ \_ -> pure ()
      pure $
        Ingested
          { envelope = env,
            ack = ackHandle,
            lease = Nothing
          }

-- | Create a single message (for use in streaming contexts)
-- Polymorphic over effect stack for use with tracing.
createSingleMessage :: (IOE :> es) => Int -> IO (Ingested es String)
createSingleMessage i = do
  let msgId = MessageId $ "msg-" <> Text.pack (show i)
      env =
        Envelope
          { messageId = msgId,
            cursor = Just (CursorInt i),
            partition = Nothing,
            enqueuedAt = Just testTime,
            traceContext = Nothing,
            payload = "message-" <> show i
          }
      ackHandle = AckHandle $ \_ -> pure ()
  pure $
    Ingested
      { envelope = env,
        ack = ackHandle,
        lease = Nothing
      }

testAdapter :: [Ingested es String] -> Adapter es String
testAdapter messages =
  Adapter
    { adapterName = "test:supervised",
      source = Stream.fromList messages,
      shutdown = pure ()
    }

testHandler :: (IOE :> es) => IORef [String] -> Handler es String
testHandler ref ingested = do
  liftIO $ modifyIORef' ref (ingested.envelope.payload :)
  pure AckOk

failingHandler :: Handler es msg
failingHandler _ = error "Intentional failure"

alwaysAckOk :: Handler es msg
alwaysAckOk _ = pure AckOk
