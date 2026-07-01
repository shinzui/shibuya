module Shibuya.Batch.ReliabilitySpec (spec) where

import Control.Concurrent.STM
  ( TVar,
    atomically,
    check,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    writeTVar,
  )
import Control.Monad (forM_)
import Data.Foldable (toList)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock
  ( TrackingAck,
    getTrackedDecisions,
    listAdapter,
    mkTrackedIngested,
    newTrackingAck,
    trackedListAdapter,
  )
import Shibuya.App
  ( AppHandle (..),
    QueueProcessor (..),
    ShutdownConfig (..),
    SupervisionStrategy (..),
    mkBatchProcessor,
    runApp,
    stopAppGracefully,
  )
import Shibuya.Batch
  ( BatchAck,
    BatchConfig (..),
    BatchHandler,
    BatchInfo (..),
    BatchKey (..),
    BatchTrigger (..),
    ackAllOk,
    ackExcept,
    defaultBatchConfig,
  )
import Shibuya.Batch.TestHarness
import Shibuya.Core.Ack
  ( AckDecision (..),
    DeadLetterReason (..),
    HaltReason (..),
    RetryDelay (..),
  )
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..), Ordering (..))
import Shibuya.Runner.Metrics
  ( BatchStats (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
  )
import Shibuya.Runner.Supervised (SupervisedProcessor (..))
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import Test.QuickCheck
import Test.QuickCheck.Monadic (assert, monadicIO, monitor, run)
import UnliftIO (throwIO)
import UnliftIO.Concurrent (threadDelay)
import Prelude hiding (Ordering)

tshowT :: Int -> Text
tshowT = Text.pack . show

-- | Run @runApp@ and fail the test loudly if it returns a Left (avoids relying on
-- a @MonadFail@ instance for @Eff@).
runAppOrFail ::
  (IOE :> es, Tracing :> es) =>
  Int ->
  [(ProcessorId, QueueProcessor es)] ->
  Eff es (AppHandle es)
runAppOrFail inbox procs = do
  res <- runApp IgnoreFailures inbox procs
  case res of
    Right app -> pure app
    Left e -> liftIO $ ioError (userError ("runApp failed: " <> show e))

-- | Read a processor's live metrics directly from its 'SupervisedProcessor' TVar
-- (via the 'AppHandle'), NOT from the Master registry. A finished or halted
-- processor unregisters its metrics from the Master in its @finally@, so
-- @getAppMetrics@ would return nothing for it; the TVar itself persists and holds
-- the final metrics.
metricsFor :: (IOE :> es) => AppHandle es -> ProcessorId -> Eff es ProcessorMetrics
metricsFor app pid =
  case Map.lookup pid app.processors of
    Just (sp, _) -> liftIO $ readTVarIO sp.metrics
    Nothing -> liftIO $ ioError (userError ("no processor " <> show pid))

--------------------------------------------------------------------------------
-- Shared handlers / builders
--------------------------------------------------------------------------------

-- | An observed batch: the info the framework passed and the ids in the batch.
data ObservedBatch = ObservedBatch
  { info :: !BatchInfo,
    ids :: ![MessageId]
  }
  deriving stock (Show)

-- | A handler that records every batch it sees and then returns the given
-- 'BatchAck' (computed from the batch).
recordingHandler ::
  (IOE :> es) =>
  IORef [ObservedBatch] ->
  (BatchInfo -> NonEmpty (Ingested es Int) -> BatchAck) ->
  BatchHandler es Int
recordingHandler ref decide bi msgs = do
  let obs = ObservedBatch bi [ing.envelope.messageId | ing <- toList msgs]
  liftIO $ atomicModifyIORef' ref (\xs -> (obs : xs, ()))
  pure (decide bi msgs)

fixedEnvelopes :: Int -> [Envelope Int]
fixedEnvelopes n = [mkEnvelope i (BatchKey "default") i | i <- [1 .. n]]

keyedEnvelopes :: [BatchKey] -> Int -> [Envelope Int]
keyedEnvelopes keys n =
  [mkEnvelope i (keys !! ((i - 1) `mod` length keys)) i | i <- [1 .. n]]

-- | Round-robin key membership for scenario #9: msg-1,3,5 belong to @ka@;
-- msg-2,4,6 belong to @kb@.
idBelongsToKey :: BatchKey -> MessageId -> Bool
idBelongsToKey (BatchKey "ka") (MessageId t) = odd (msgNum t)
idBelongsToKey (BatchKey "kb") (MessageId t) = even (msgNum t)
idBelongsToKey _ _ = True

msgNum :: Text -> Int
msgNum t = read (drop 4 (Text.unpack t)) -- "msg-<n>"

-- | A gated tracked adapter: yields tracked-ingested messages then blocks until
-- 'shutdown' opens the gate, keeping the stream open so the timeout ticker (not an
-- immediate end-of-input flush) is what emits an accumulated partial batch.
gatedTrackedAdapter ::
  (IOE :> es) => TVar Bool -> TrackingAck -> [Envelope Int] -> Adapter es Int
gatedTrackedAdapter gate tracking envs =
  Adapter
    { adapterName = "test:gated-tracked",
      source = Stream.unfoldrM step (map (mkTrackedIngested tracking) envs),
      shutdown = liftIO $ atomically $ writeTVar gate True
    }
  where
    step [] = do
      liftIO $ atomically $ readTVar gate >>= check
      pure Nothing
    step (m : ms) = pure (Just (m, ms))

--------------------------------------------------------------------------------
-- Property driver
--------------------------------------------------------------------------------

scenarioConfig :: BatchScenario -> BatchConfig es Int
scenarioConfig s =
  defaultBatchConfig
    { batchSize = s.batchSize,
      batchTimeout = fromIntegral s.batchTimeoutMs / 1000,
      batchKey = scenarioBatchKey
    }

-- | A batch handler that finalizes each message with the intended per-message
-- decision. For every message whose intended decision is a dead-letter, it emits
-- an override; everything else falls back to 'AckOk'. Exercises both the override
-- and fallback paths.
intendedHandler :: Map MessageId AckDecision -> BatchHandler es Int
intendedHandler intended _info msgs =
  pure $
    ackExcept
      [ (mid, d)
      | ing <- toList msgs,
        let mid = ing.envelope.messageId,
        Just d <- [Map.lookup mid intended],
        d /= AckOk
      ]

-- | Run a scenario end-to-end through the real @runApp@ path, flush the tail via a
-- graceful shutdown, and return the tracked acknowledgements plus final metrics.
runScenario ::
  BatchScenario ->
  IO ([(MessageId, AckDecision)], ProcessorMetrics)
runScenario s = runEff $ runTracingNoop $ do
  tracking <- newTrackingAck
  let pid = ProcessorId "batch"
      adapter = trackedListAdapter tracking (scenarioEnvelopes s)
      proc = mkBatchProcessor adapter (intendedHandler (scenarioIntended s)) (scenarioConfig s)
  app <- runAppOrFail 100 [(pid, proc)]
  _drained <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
  m <- metricsFor app pid
  tracked <- getTrackedDecisions tracking
  pure (tracked, m)

--------------------------------------------------------------------------------
-- Spec
--------------------------------------------------------------------------------

spec :: Spec
spec = describe "Shibuya.Batch reliability" $ do
  describe "successful-finalization property" $ do
    it "finalizes every normal-path message once with the intended decision" $
      withMaxSuccess 50 $
        forAll genScenario $ \s -> monadicIO $ do
          (tracked, metrics) <- run (runScenario s)
          let expected = scenarioIntended s
          case finalizedExactlyOnce tracked expected of
            Left err -> do
              monitor (counterexample ("successful-finalization violated: " <> err))
              assert False
            Right () -> pure ()
          monitor
            ( counterexample
                ( "accounting: processed="
                    <> show metrics.stats.processed
                    <> " failed="
                    <> show metrics.stats.failed
                    <> " n="
                    <> show s.msgCount
                )
            )
          assert (metrics.stats.processed + metrics.stats.failed == s.msgCount)
          assert (metrics.batch.batchedMessages == s.msgCount)

  -- Non-vacuity of the checker itself: feed it perturbed tracked lists and prove
  -- it fires. Without these, a checker that always returns Right () would pass
  -- the property above vacuously.
  describe "finalizedExactlyOnce checker (non-vacuity)" $ do
    let mid i = MessageId ("msg-" <> tshowT i)
        okFor is = Map.fromList [(mid i, AckOk) | i <- is]
        failsWith needle = either (needle `isInfixOf`) (const False)
    it "accepts a complete, once-each tracked list regardless of order" $
      finalizedExactlyOnce [(mid 2, AckOk), (mid 1, AckOk)] (okFor [1, 2])
        `shouldBe` Right ()
    it "rejects a double-finalized message" $
      finalizedExactlyOnce [(mid 1, AckOk), (mid 2, AckOk), (mid 1, AckOk)] (okFor [1, 2])
        `shouldSatisfy` failsWith "finalized more than once"
    it "rejects a missing finalization" $
      finalizedExactlyOnce [(mid 1, AckOk)] (okFor [1, 2])
        `shouldSatisfy` failsWith "id set mismatch"
    it "rejects an unexpected finalization" $
      finalizedExactlyOnce [(mid 1, AckOk), (mid 2, AckOk)] (okFor [1])
        `shouldSatisfy` failsWith "id set mismatch"
    it "rejects a finalization with the wrong decision" $
      finalizedExactlyOnce [(mid 1, AckRetry (RetryDelay 1))] (okFor [1])
        `shouldSatisfy` failsWith "wrong decision"

  describe "scenarios" $ do
    -- #2 Timeout flush (via a gated adapter so the ticker, not EOF, flushes).
    it "flushes a partial batch on timeout" $ do
      observedRef <- newIORef ([] :: [ObservedBatch])
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, observed) <- runEff $ runTracingNoop $ do
        gate <- liftIO $ newTVarIO False
        let pid = ProcessorId "timeout"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 100, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handler = recordingHandler observedRef (\_ _ -> ackAllOk)
            adapter = gatedTrackedAdapter gate tracking (fixedEnvelopes 3)
            proc = mkBatchProcessor adapter handler cfg
        app <- runAppOrFail 100 [(pid, proc)]
        liftIO $ threadDelay 400000 -- 400 ms > 100 ms timeout: ticker flushes
        t0 <- getTrackedDecisions tracking
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        o <- liftIO $ readIORef observedRef
        pure (t0, o)
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 3 :: Int]])
        `shouldBe` Right ()
      map (.info.trigger) observed `shouldSatisfy` elem TriggerTimeout

    -- #3 Partial failure.
    it "acks a partial-failure batch: exactly the failed messages dead-letter" $ do
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, metrics) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "partial"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 5, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            fails =
              [ (MessageId "msg-2", AckDeadLetter MaxRetriesExceeded),
                (MessageId "msg-4", AckDeadLetter (PoisonPill "bad"))
              ]
            handler _ _ = pure (ackExcept fails)
            adapter = trackedListAdapter tracking (fixedEnvelopes 5)
            proc = mkBatchProcessor adapter handler cfg
        app <- runAppOrFail 100 [(pid, proc)]
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        t <- getTrackedDecisions tracking
        m <- metricsFor app pid
        pure (t, m)
      let expected =
            Map.fromList
              [ (MessageId "msg-1", AckOk),
                (MessageId "msg-2", AckDeadLetter MaxRetriesExceeded),
                (MessageId "msg-3", AckOk),
                (MessageId "msg-4", AckDeadLetter (PoisonPill "bad")),
                (MessageId "msg-5", AckOk)
              ]
      finalizedExactlyOnce tracked expected `shouldBe` Right ()
      metrics.stats.failed `shouldBe` 2
      metrics.stats.processed `shouldBe` 3

    -- #4 Batch-handler exception -> whole-batch AckRetry, app survives.
    it "on batch-handler exception, every message retries and the app survives" $ do
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, drained) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "exc"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 4, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handler _ _ = error "boom in batch"
            adapter = trackedListAdapter tracking (fixedEnvelopes 4)
            proc = mkBatchProcessor adapter handler cfg
        app <- runAppOrFail 100 [(pid, proc)]
        d <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        t <- getTrackedDecisions tracking
        pure (t, d)
      let expected = Map.fromList [(MessageId ("msg-" <> tshowT i), AckRetry (RetryDelay 0)) | i <- [1 .. 4 :: Int]]
      finalizedExactlyOnce tracked expected `shouldBe` Right ()
      drained `shouldBe` True

    -- #5 Transient finalizer retry.
    it "retries a transient finalizer failure and records one success" $ do
      attemptRef <- newIORef (0 :: Int)
      trackRef <- newIORef ([] :: [(MessageId, AckDecision)])
      (tracked, attempts) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "retry"
            mid = MessageId "msg-1"
            flakyHandle = AckHandle $ \d -> do
              n <- liftIO $ atomicModifyIORef' attemptRef (\c -> (c + 1, c))
              if n < 2
                then liftIO $ throwIO (userError "transient")
                else liftIO $ modifyIORef' trackRef ((mid, d) :)
            ing = Ingested {envelope = mkEnvelope 1 (BatchKey "default") 1, ack = flakyHandle, lease = Nothing}
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 1, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handler _ _ = pure ackAllOk
            proc = mkBatchProcessor (listAdapter [ing]) handler cfg
        app <- runAppOrFail 100 [(pid, proc)]
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        t <- liftIO $ readIORef trackRef
        a <- liftIO $ readIORef attemptRef
        pure (t, a)
      tracked `shouldBe` [(MessageId "msg-1", AckOk)]
      attempts `shouldBe` 3

    -- #6 Permanent finalizer failure -> fail loud, name the id, still attempt others.
    it "exhausts permanent finalizer failures and halts loudly with the failed MessageId" $ do
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, mState) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "perm"
            failHandle = AckHandle $ \_ -> liftIO $ throwIO (userError "permanent")
            ing1 = Ingested {envelope = mkEnvelope 1 (BatchKey "default") 1, ack = failHandle, lease = Nothing}
            ing2 = mkTrackedIngested tracking (mkEnvelope 2 (BatchKey "default") 2)
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 2, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handler _ _ = pure ackAllOk
            proc = mkBatchProcessor (listAdapter [ing1, ing2]) handler cfg
        app <- runAppOrFail 100 [(pid, proc)]
        liftIO $ threadDelay 700000 -- allow the [10,50,250]ms retry schedule to exhaust
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app
        t <- getTrackedDecisions tracking
        m <- metricsFor app pid
        pure (t, m.state)
      case mState of
        Failed msg _ -> msg `shouldSatisfy` Text.isInfixOf "msg-1"
        other -> expectationFailure ("expected Failed, got: " <> show other)
      -- The other message was still attempted and successfully finalized.
      tracked `shouldBe` [(MessageId "msg-2", AckOk)]

    -- #7 Halt in a batch, with isolation of a second processor.
    it "halt in one batch finalizes that batch, halts its processor, and spares others" $ do
      trackingA <- runEff $ runTracingNoop newTrackingAck
      trackingB <- runEff $ runTracingNoop newTrackingAck
      (trackedA, trackedB, mA) <- runEff $ runTracingNoop $ do
        let pidA = ProcessorId "halt-A"
            pidB = ProcessorId "ok-B"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 3, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handlerA _ _ = pure (ackExcept [(MessageId "msg-2", AckHalt (HaltFatal "halt in batch"))])
            handlerB _ _ = pure (ackExcept [])
            procA = mkBatchProcessor (trackedListAdapter trackingA (fixedEnvelopes 3)) handlerA cfg
            procB = mkBatchProcessor (trackedListAdapter trackingB (fixedEnvelopes 3)) handlerB cfg
        app <- runAppOrFail 100 [(pidA, procA), (pidB, procB)]
        liftIO $ threadDelay 300000
        mA' <- metricsFor app pidA
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 1}) app
        tA <- getTrackedDecisions trackingA
        tB <- getTrackedDecisions trackingB
        pure (tA, tB, mA')
      finalizedExactlyOnce
        trackedA
        ( Map.fromList
            [ (MessageId "msg-1", AckOk),
              (MessageId "msg-2", AckHalt (HaltFatal "halt in batch")),
              (MessageId "msg-3", AckOk)
            ]
        )
        `shouldBe` Right ()
      case mA.state of
        Failed msg _ -> msg `shouldSatisfy` Text.isInfixOf "halt in batch"
        other -> expectationFailure ("expected A Failed, got: " <> show other)
      finalizedExactlyOnce
        trackedB
        (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 3 :: Int]])
        `shouldBe` Right ()

    -- #8 Graceful drain flush (gated adapter so the flush comes from shutdown).
    it "flushes a pending partial batch on graceful shutdown" $ do
      observedRef <- newIORef ([] :: [ObservedBatch])
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, drained, observed) <- runEff $ runTracingNoop $ do
        gate <- liftIO $ newTVarIO False
        let pid = ProcessorId "drain"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 100, batchTimeout = 30, batchKey = scenarioBatchKey}
            handler = recordingHandler observedRef (\_ _ -> ackAllOk)
            adapter = gatedTrackedAdapter gate tracking (fixedEnvelopes 3)
            proc = mkBatchProcessor adapter handler cfg
        app <- runAppOrFail 100 [(pid, proc)]
        liftIO $ threadDelay 100000 -- accumulate (no size/timeout flush)
        d <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        t <- getTrackedDecisions tracking
        o <- liftIO $ readIORef observedRef
        pure (t, d, o)
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 3 :: Int]])
        `shouldBe` Right ()
      drained `shouldBe` True
      map (.info.trigger) observed `shouldSatisfy` elem TriggerFlush

    -- #9 Multiple batch keys accumulate independently.
    it "accumulates independent per-key batches and acks all exactly once" $ do
      observedRef <- newIORef ([] :: [ObservedBatch])
      tracking <- runEff $ runTracingNoop newTrackingAck
      (tracked, observed) <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "multi-key"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 3, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handler = recordingHandler observedRef (\_ _ -> ackAllOk)
            adapter = trackedListAdapter tracking (keyedEnvelopes [BatchKey "ka", BatchKey "kb"] 6)
            proc = mkBatchProcessor adapter handler cfg
        app <- runAppOrFail 100 [(pid, proc)]
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        t <- getTrackedDecisions tracking
        o <- liftIO $ readIORef observedRef
        pure (t, o)
      forM_ observed $ \ob ->
        all (idBelongsToKey ob.info.batchKey) ob.ids `shouldBe` True
      map (.info.batchKey) observed `shouldSatisfy` (\ks -> BatchKey "ka" `elem` ks && BatchKey "kb" `elem` ks)
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 6 :: Int]])
        `shouldBe` Right ()

    -- #10 Per-key FIFO under concurrency (Async 2).
    it "preserves per-key FIFO while allowing cross-key concurrency" $ do
      (violated, tracked) <- runEff $ runTracingNoop $ do
        active <- liftIO $ newTVarIO Set.empty
        violatedVar <- liftIO $ newTVarIO False
        tracking <- newTrackingAck
        let pid = ProcessorId "fifo"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 1, batchTimeout = 0.1, batchKey = scenarioBatchKey}
            handler info _ = do
              liftIO $ atomically $ do
                a <- readTVar active
                if info.batchKey `Set.member` a
                  then writeTVar violatedVar True
                  else pure ()
                modifyTVar' active (Set.insert info.batchKey)
              liftIO $ threadDelay 30000
              liftIO $ atomically $ modifyTVar' active (Set.delete info.batchKey)
              pure ackAllOk
            keys = [BatchKey "same", BatchKey "same", BatchKey "same", BatchKey "other", BatchKey "other"]
            adapter = trackedListAdapter tracking (keyedEnvelopes keys 5)
            proc =
              BatchingProcessor
                { adapter = adapter,
                  batchHandler = handler,
                  batchConfig = cfg,
                  ordering = Unordered,
                  concurrency = Async 2
                }
        app <- runAppOrFail 100 [(pid, proc)]
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 5}) app
        v <- liftIO $ readTVarIO violatedVar
        t <- getTrackedDecisions tracking
        pure (v, t)
      violated `shouldBe` False
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 5 :: Int]])
        `shouldBe` Right ()

    -- #11 Backpressure liveness (limited: a no-loss proxy, not a memory measurement).
    it "under a tiny inbox and a slow handler, loses no messages (backpressure liveness; see limitation)" $ do
      tracking <- runEff $ runTracingNoop newTrackingAck
      tracked <- runEff $ runTracingNoop $ do
        let pid = ProcessorId "backpressure"
            cfg = (defaultBatchConfig @_ @Int) {batchSize = 4, batchTimeout = 0.05, batchKey = scenarioBatchKey}
            handler _ _ = do
              liftIO $ threadDelay 5000 -- 5 ms per batch
              pure ackAllOk
            adapter = trackedListAdapter tracking (fixedEnvelopes 20)
            proc = mkBatchProcessor adapter handler cfg
        app <- runAppOrFail 2 [(pid, proc)] -- inbox size 2
        _ <- stopAppGracefully (ShutdownConfig {drainTimeout = 10}) app
        getTrackedDecisions tracking
      finalizedExactlyOnce tracked (Map.fromList [(MessageId ("msg-" <> tshowT i), AckOk) | i <- [1 .. 20 :: Int]])
        `shouldBe` Right ()
