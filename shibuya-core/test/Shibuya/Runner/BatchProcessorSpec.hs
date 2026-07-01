module Shibuya.Runner.BatchProcessorSpec (spec) where

import Control.Concurrent.STM
  ( atomically,
    modifyTVar',
    newTVarIO,
    readTVar,
    readTVarIO,
    writeTVar,
  )
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Shibuya.Adapter.Mock
  ( TrackingAck (..),
    getTrackedDecisions,
    newTrackingAck,
    trackingAckHandle,
  )
import Shibuya.Batch
  ( BatchInfo (..),
    BatchKey (..),
    BatchTrigger (..),
    ackAllOk,
    ackExcept,
    defaultBatchKey,
    withFallback,
  )
import Shibuya.Core (ProcessorHalt (..))
import Shibuya.Core.Ack
  ( AckDecision (..),
    DeadLetterReason (..),
    HaltReason (..),
    RetryDelay (..),
  )
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Runner.BatchProcessor (runBatchesWithMetrics)
import Shibuya.Runner.Metrics
  ( BatchStats (..),
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
  )
import Shibuya.Telemetry.Effect (runTracingNoop)
import Test.Hspec
import UnliftIO (throwIO, try)
import UnliftIO.Concurrent (threadDelay)

spec :: Spec
spec = describe "Shibuya.Runner.BatchProcessor" $ do
  describe "decision resolution and finalization (M1)" $ do
    it "finalizes each of 5 messages successfully with per-message decisions" $ do
      (tracked, metrics) <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        batch <- buildBatch tracking 5 TriggerSize
        let handler _info _msgs =
              pure $
                ackExcept
                  [ (MessageId "msg-2", AckDeadLetter MaxRetriesExceeded),
                    (MessageId "msg-4", AckDeadLetter (PoisonPill "x"))
                  ]
        m <- runBatchesWithMetrics (ProcessorId "m1") Serial handler [batch]
        t <- getTrackedDecisions tracking
        pure (t, m)

      -- Each id appears exactly once in the successful-finalization list.
      sort (map fst tracked) `shouldBe` expectedIds
      lookup (MessageId "msg-1") tracked `shouldBe` Just AckOk
      lookup (MessageId "msg-2") tracked `shouldBe` Just (AckDeadLetter MaxRetriesExceeded)
      lookup (MessageId "msg-3") tracked `shouldBe` Just AckOk
      lookup (MessageId "msg-4") tracked `shouldBe` Just (AckDeadLetter (PoisonPill "x"))
      lookup (MessageId "msg-5") tracked `shouldBe` Just AckOk

      metrics.batch.batchesEmitted `shouldBe` 1
      metrics.batch.batchedMessages `shouldBe` 5
      metrics.batch.partialFailures `shouldBe` 1
      metrics.batch.sizeTriggered `shouldBe` 1
      metrics.stats.processed `shouldBe` 3
      metrics.stats.failed `shouldBe` 2

    it "retries a transient finalizer failure and records one successful finalization" $ do
      tracked <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        counter <- liftIO $ newIORef (0 :: Int)
        -- A single-message batch whose finalizer throws its first two attempts
        -- then records success on the third.
        let mid = MessageId "flaky-1"
            ing =
              Ingested
                { envelope = mkEnv 1 mid,
                  ack = flakyAckHandle counter tracking mid,
                  lease = Nothing
                }
            info =
              BatchInfo
                { batchKey = defaultBatchKey,
                  size = 1,
                  trigger = TriggerSize,
                  partition = Nothing
                }
        _ <- runBatchesWithMetrics (ProcessorId "m1-flaky") Serial (\_ _ -> pure ackAllOk) [(info, NE.fromList [ing])]
        getTrackedDecisions tracking

      -- Exactly one successful finalization despite two prior throws.
      tracked `shouldBe` [(MessageId "flaky-1", AckOk)]

  describe "exception fallback (M2)" $ do
    it "finalizes all 5 with AckRetry when the handler throws" $ do
      (tracked, metrics) <- runEff $ runTracingNoop $ do
        tracking <- newTrackingAck
        batch <- buildBatch tracking 5 TriggerTimeout
        let handler _info _msgs = error "boom"
        m <- runBatchesWithMetrics (ProcessorId "m2-exc") Serial handler [batch]
        t <- getTrackedDecisions tracking
        pure (t, m)

      length tracked `shouldBe` 5
      sort (map fst tracked) `shouldBe` expectedIds
      all ((== AckRetry (RetryDelay 0)) . snd) tracked `shouldBe` True
      metrics.stats.failed `shouldBe` 5
      metrics.batch.partialFailures `shouldBe` 0
      metrics.batch.timeoutTriggered `shouldBe` 1

  describe "halt (M2)" $ do
    it "finalizes all 5, sets halt, and the driver throws ProcessorHalt" $ do
      -- Build the tracking ack OUTSIDE the aborted action so it survives the throw.
      tracking <- runEff $ runTracingNoop newTrackingAck
      result <- try $ runEff $ runTracingNoop $ do
        batch <- buildBatch tracking 5 TriggerFlush
        let handler _info _msgs =
              pure $
                withFallback
                  AckOk
                  [(MessageId "msg-3", AckHalt (HaltFatal "halt on 3"))]
        _ <- runBatchesWithMetrics (ProcessorId "m2-halt") Serial handler [batch]
        pure ()

      case result of
        Left (ProcessorHalt reason) -> reason `shouldBe` HaltFatal "halt on 3"
        Right () -> expectationFailure "expected ProcessorHalt"

      tracked <- runEff $ runTracingNoop $ getTrackedDecisions tracking
      sort (map fst tracked) `shouldBe` expectedIds
      lookup (MessageId "msg-3") tracked `shouldBe` Just (AckHalt (HaltFatal "halt on 3"))

  describe "finalizer failure (M2)" $ do
    it "exhausts retries, names the failed MessageId, and still attempts the rest" $ do
      -- Two-message batch: msg-1 finalizer always throws; msg-2 records normally.
      tracking <- runEff $ runTracingNoop newTrackingAck
      result <- try $ runEff $ runTracingNoop $ do
        let mid1 = MessageId "perm-1"
            mid2 = MessageId "perm-2"
            ing1 =
              Ingested
                { envelope = mkEnv 1 mid1,
                  ack = alwaysFailAckHandle,
                  lease = Nothing
                }
            ing2 =
              Ingested
                { envelope = mkEnv 2 mid2,
                  ack = trackingAckHandle tracking mid2,
                  lease = Nothing
                }
            info =
              BatchInfo
                { batchKey = defaultBatchKey,
                  size = 2,
                  trigger = TriggerSize,
                  partition = Nothing
                }
        _ <- runBatchesWithMetrics (ProcessorId "m2-fin") Serial (\_ _ -> pure ackAllOk) [(info, NE.fromList [ing1, ing2])]
        pure ()

      case result of
        Left (ProcessorHalt (HaltFatal msg)) ->
          msg `shouldSatisfy` Text.isInfixOf "perm-1"
        Left other -> expectationFailure ("unexpected halt reason: " <> show other)
        Right () -> expectationFailure "expected ProcessorHalt from exhausted finalization"

      -- The other message was still attempted and finalized despite msg-1 failing.
      tracked <- runEff $ runTracingNoop $ getTrackedDecisions tracking
      tracked `shouldBe` [(MessageId "perm-2", AckOk)]

  describe "keyed concurrency (M2)" $ do
    it "does not overlap batches with the same BatchKey under Async" $ do
      violation <- runEff $ runTracingNoop $ do
        activeKeys <- liftIO $ newTVarIO Set.empty
        violated <- liftIO $ newTVarIO False
        -- Handler marks its key active on entry (flagging a violation if it was
        -- already active), holds it briefly, then clears it.
        let handler info _msgs = do
              liftIO $ atomically $ do
                active <- readTVar activeKeys
                if info.batchKey `Set.member` active
                  then writeTVar violated True
                  else pure ()
                modifyTVar' activeKeys (Set.insert info.batchKey)
              liftIO $ threadDelay 20000
              liftIO $ atomically $ modifyTVar' activeKeys (Set.delete info.batchKey)
              pure ackAllOk
        -- Three batches for key "a" (must serialize) plus two for "b".
        batches <- traverse (\(i, k) -> buildKeyedBatch i (BatchKey k)) (zip [1 ..] ["a", "a", "a", "b", "b"])
        _ <- runBatchesWithMetrics (ProcessorId "m2-keyed") (Async 3) handler batches
        liftIO $ readTVarIO violated
      violation `shouldBe` False

expectedIds :: [MessageId]
expectedIds = [MessageId ("msg-" <> tshow i) | i <- [1 .. 5 :: Int]]

-- | Envelope for message @i@ with the given id.
mkEnv :: Int -> MessageId -> Envelope String
mkEnv i mid =
  Envelope
    { messageId = mid,
      cursor = Nothing,
      partition = Nothing,
      enqueuedAt = Just testTime,
      traceContext = Nothing,
      headers = Nothing,
      attempt = Nothing,
      attributes = HashMap.empty,
      payload = "payload-" <> show i
    }

-- | Build a batch of @n@ messages (ids @msg-1@..@msg-n@) whose acks record into
-- the given TrackingAck.
buildBatch ::
  (IOE :> es) =>
  TrackingAck ->
  Int ->
  BatchTrigger ->
  Eff es (BatchInfo, NonEmpty (Ingested es String))
buildBatch tracking n trig = do
  let mk i =
        let mid = MessageId ("msg-" <> tshow i)
         in Ingested
              { envelope = mkEnv i mid,
                ack = trackingAckHandle tracking mid,
                lease = Nothing
              }
      msgs = map mk [1 .. n]
      info =
        BatchInfo
          { batchKey = defaultBatchKey,
            size = n,
            trigger = trig,
            partition = Nothing
          }
  pure (info, NE.fromList msgs)

-- | A single-message batch with the given batch key (no-op tracking ack); used
-- to exercise the keyed scheduler.
buildKeyedBatch ::
  (IOE :> es) =>
  Int ->
  BatchKey ->
  Eff es (BatchInfo, NonEmpty (Ingested es String))
buildKeyedBatch i key = do
  let mid = MessageId ("k-" <> tshow i)
      ing =
        Ingested
          { envelope = mkEnv i mid,
            ack = AckHandle (\_ -> pure ()),
            lease = Nothing
          }
      info =
        BatchInfo
          { batchKey = key,
            size = 1,
            trigger = TriggerSize,
            partition = Nothing
          }
  pure (info, NE.fromList [ing])

-- | A finalizer that throws its first two attempts, then records success.
flakyAckHandle :: (IOE :> es) => IORef Int -> TrackingAck -> MessageId -> AckHandle es
flakyAckHandle counter tracking mid =
  AckHandle $ \decision -> do
    n <- liftIO $ atomicModifyIORef' counter (\c -> (c + 1, c))
    if n < 2
      then liftIO $ throwIO (userError "flaky finalize")
      else liftIO $ modifyIORef' tracking.trackedDecisions ((mid, decision) :)

-- | A finalizer that always throws (permanent adapter failure).
alwaysFailAckHandle :: (IOE :> es) => AckHandle es
alwaysFailAckHandle = AckHandle $ \_ -> liftIO $ throwIO (userError "permanent finalize failure")

testTime :: UTCTime
testTime = UTCTime (fromGregorian 2026 1 1) 0

tshow :: (Show a) => a -> Text
tshow = Text.pack . show
