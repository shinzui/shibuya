module Shibuya.Core.MetricsSpec (spec) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Monad (forM_, replicateM, replicateM_)
import Data.IORef
import Data.Maybe (fromJust)
import Data.Time (UTCTime (..), fromGregorian)
import Data.Word (Word64)
import Shibuya.Core.Metrics
import Shibuya.Core.Types (MessageId (..))
import Test.Hspec
import UnliftIO qualified as UIO

spec :: Spec
spec = describe "Detailed metrics" $ do
  it "accepts timestamp zero, bounds claims, and counts slot misses" $ do
    (_, h) <- handle 2
    sampleMetrics h >>= \m -> m.latency `shouldBe` Nothing
    a <- claimInFlightSlot h (MessageId "a")
    b <- claimInFlightSlot h (MessageId "b")
    a `shouldNotBe` b
    claimInFlightSlot h (MessageId "c") `shouldReturn` (-1)
    slotMisses h `shouldReturn` 1
    sampleMetrics h >>= \m -> fmap (.messageId) m.oldestInFlight `shouldBe` Just (MessageId "a")
    abandonInFlightSlot h a
    abandonInFlightSlot h b
    sampleMetrics h >>= \m -> m.oldestInFlight `shouldBe` Nothing

  it "records cumulative buckets and nanosecond sums on release and reuse" $ do
    (clock, h) <- handle 1
    replicateM_ 100 $ do
      start <- readIORef clock
      slot <- claimInFlightSlot h (MessageId "a")
      writeIORef clock (start + 3_000_000)
      releaseInFlightSlot h slot
    m <- sampleMetrics h
    let summary = fromJust m.latency
    summary.count `shouldBe` 100
    summary.sumSeconds `shouldBe` 0.3
    map (.count) summary.buckets `shouldBe` replicate 5 0 ++ replicate 13 100
    m.oldestInFlight `shouldBe` Nothing

  it "reports oldest identity, start and growing age together" $ do
    (clock, h) <- handle 2
    a <- claimInFlightSlot h (MessageId "a")
    writeIORef clock 1_000_000_000
    _ <- claimInFlightSlot h (MessageId "b")
    writeIORef clock 2_000_000_000
    sampleMetrics h >>= \m -> m.oldestInFlight `shouldBe` Just (OldestInFlight (MessageId "a") epoch 2)
    releaseInFlightSlot h a
    sampleMetrics h >>= \m -> fmap (.messageId) m.oldestInFlight `shouldBe` Just (MessageId "b")

  it "counts observations beyond the finite bounds without wrapping the sum" $ do
    (clock, h) <- handle 1
    slot <- claimInFlightSlot h (MessageId "long")
    writeIORef clock 70_000_000_000
    releaseInFlightSlot h slot
    m <- sampleMetrics h
    let summary = fromJust m.latency
    summary.count `shouldBe` 1
    summary.sumSeconds `shouldBe` 70
    map (.count) summary.buckets `shouldBe` replicate 18 0

  it "never reads the detail clock on the basic hooks" $ do
    calls <- newIORef (0 :: Int)
    h <- newMetricsHandleWithClock (modifyIORef' calls (+ 1) >> pure 0) epoch
    initialCalls <- readIORef calls
    claimInFlightSlot h (MessageId "a") `shouldReturn` (-1)
    releaseInFlightSlot h (-1)
    abandonInFlightSlot h (-1)
    m <- sampleMetrics h
    m.latency `shouldBe` Nothing
    m.oldestInFlight `shouldBe` Nothing
    readIORef calls `shouldReturn` initialCalls

  it "aggregates lifetime nanoseconds beyond a Word64 across occupied slots" $ do
    (clock, h) <- handle 2
    a <- claimInFlightSlot h (MessageId "a")
    b <- claimInFlightSlot h (MessageId "b")
    writeIORef clock maxBound
    releaseInFlightSlot h a
    releaseInFlightSlot h b
    m <- sampleMetrics h
    let summary = fromJust m.latency
    summary.count `shouldBe` 2
    summary.sumSeconds `shouldBe` (fromInteger (2 * toInteger (maxBound :: Word64)) / 1e9)
    map (.count) summary.buckets `shouldBe` replicate 18 0
    m.oldestInFlight `shouldBe` Nothing

  it "publishes complete slots and reuses bounded storage at 1/4/64/256 concurrency" $ do
    forM_ [1, 4, 64, 256] $ \capacity -> do
      (_, h) <- handle capacity
      replicateM_ 100 $ do
        gate <- newEmptyMVar
        results <- replicateM capacity newEmptyMVar
        mapM_ (\out -> forkIO (takeMVar gate >> claimInFlightSlot h (MessageId "same") >>= putMVar out)) results
        replicateM_ capacity (putMVar gate ())
        claimed <- mapM takeMVar results
        length (filter (>= 0) claimed) `shouldBe` capacity
        slotMisses h `shouldReturn` 0
        sampleMetrics h >>= \m -> fmap (.messageId) m.oldestInFlight `shouldBe` Just (MessageId "same")
        mapM_ (abandonInFlightSlot h) claimed
        sampleMetrics h >>= \m -> m.oldestInFlight `shouldBe` Nothing

  it "samples coherently at gated claim and release clock boundaries" $ replicateM_ 100 $ do
    calls <- newIORef (0 :: Int)
    claiming <- newEmptyMVar
    publish <- newEmptyMVar
    releasing <- newEmptyMVar
    complete <- newEmptyMVar
    let clock = do
          n <- atomicModifyIORef' calls (\n -> (n + 1, n))
          case n of
            0 -> pure 0
            1 -> putMVar claiming () >> takeMVar publish >> pure 0
            2 -> putMVar releasing () >> takeMVar complete >> pure 3_000_000
            _ -> pure 3_000_000
    h <- newMetricsHandleWithClockAndDetail clock (MetricsDetailed defaultDetailOptions) 1 epoch
    claim <- UIO.async $ claimInFlightSlot h (MessageId "gated")
    takeMVar claiming
    sampleMetrics h >>= \m -> m.oldestInFlight `shouldBe` Nothing
    putMVar publish ()
    slot <- UIO.wait claim
    release <- UIO.async $ releaseInFlightSlot h slot
    takeMVar releasing
    m <- sampleMetrics h
    fmap (.messageId) m.oldestInFlight `shouldBe` Just (MessageId "gated")
    m.latency `shouldBe` Nothing
    putMVar complete ()
    UIO.wait release
    final <- sampleMetrics h
    final.oldestInFlight `shouldBe` Nothing
    fmap (.count) final.latency `shouldBe` Just 1

  it "rejects invalid detail options and concurrency before reading the clock" $ do
    let noClock = error "clock acquired before validation"
    newMetricsHandleWithClockAndDetail noClock (MetricsDetailed (DetailOptions (-1))) 1 epoch `shouldThrow` anyIOException
    newMetricsHandleWithClockAndDetail noClock (MetricsDetailed defaultDetailOptions) 0 epoch `shouldThrow` anyIOException

epoch :: UTCTime
epoch = UTCTime (fromGregorian 2026 1 1) 0

handle :: Int -> IO (IORef Word64, MetricsHandle)
handle n = do
  clock <- newIORef 0
  h <- newMetricsHandleWithClockAndDetail (readIORef clock) (MetricsDetailed defaultDetailOptions) n epoch
  pure (clock, h)
