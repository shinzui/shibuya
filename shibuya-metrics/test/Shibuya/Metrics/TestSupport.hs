module Shibuya.Metrics.TestSupport
  ( fixedTime,
    fixtureMetrics,
    fixtureProcessor,
    withMaster,
    registerIdleProcessor,
    registerFailedProcessor,
    registerPrometheusFixtures,
    getResponse,
    assertGolden,
  )
where

import Control.Concurrent.NQE.Supervisor (Strategy (IgnoreAll))
import Control.Concurrent.STM (atomically, modifyTVar')
import Control.Exception (bracket)
import Control.Monad (replicateM_)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import Effectful (runEff)
import Network.Wai (Application)
import Network.Wai.Test (SResponse, defaultRequest, request, runSession, setPath)
import Paths_shibuya_metrics (getDataFileName)
import Shibuya.App (Master)
import Shibuya.Core.Metrics
  ( AckDecisionMetric (CountProcessed),
    BatchStats (..),
    InFlightInfo (..),
    MetricsHandle (..),
    MetricsMap,
    ProcessorId (..),
    ProcessorMetrics (..),
    ProcessorState (..),
    StreamStats (..),
    beginProcessing,
    finishProcessing,
    incrementReceived,
    newMetricsHandle,
  )
import Shibuya.Internal.Runner.Master
  ( registerProcessor,
    startMaster,
    stopMaster,
  )
import Test.Hspec (Expectation, shouldBe)

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 9 20) 12_345

fixtureMetrics :: MetricsMap
fixtureMetrics =
  Map.fromList
    [ (ProcessorId "failed", fixtureProcessor (Failed "boom" (at 90)) 20),
      (ProcessorId "idle", fixtureProcessor Idle 0),
      (ProcessorId "processing", fixtureProcessor (Processing (InFlightInfo 2 4) (at 60)) 10),
      (ProcessorId "stopped", fixtureProcessor Stopped 30)
    ]
  where
    at seconds = fixedTime {utctDayTime = seconds}

fixtureProcessor :: ProcessorState -> Int -> ProcessorMetrics
fixtureProcessor state offset =
  ProcessorMetrics
    { state,
      stats = StreamStats (offset + 1) (offset + 2) (offset + 3),
      batch = BatchStats (offset + 4) (offset + 5) (offset + 6) (offset + 7) (offset + 8) (offset + 9),
      startedAt = fixedTime
    }

withMaster :: (Master -> IO a) -> IO a
withMaster = bracket acquire release
  where
    acquire = runEff $ startMaster IgnoreAll
    release master = runEff $ stopMaster master

registerIdleProcessor :: Master -> ProcessorId -> IO MetricsHandle
registerIdleProcessor master pid = do
  handle <- newMetricsHandle fixedTime
  runEff $ registerProcessor master pid handle
  pure handle

registerFailedProcessor :: Master -> ProcessorId -> IO MetricsHandle
registerFailedProcessor master pid = do
  handle <- registerIdleProcessor master pid
  _ <- beginProcessing handle 1
  finishProcessing handle (Left "fixture failure")
  pure handle

registerPrometheusFixtures :: Master -> IO ()
registerPrometheusFixtures master = do
  _ <- registerIdleProcessor master (ProcessorId "idle")

  processing <- registerIdleProcessor master (ProcessorId "processing")
  replicateM_ 2 $ incrementReceived processing
  _ <- beginProcessing processing 4

  failed <- registerIdleProcessor master (ProcessorId "failed")
  incrementReceived failed
  _ <- beginProcessing failed 1
  finishProcessing failed (Left "fixture failure")

  stopped <- registerIdleProcessor master (ProcessorId "stopped")
  replicateM_ 4 $ incrementReceived stopped
  _ <- beginProcessing stopped 1
  finishProcessing stopped (Right CountProcessed)
  atomically $ modifyTVar' stopped.cold $ \metrics -> metrics {state = Stopped}

getResponse :: Application -> ByteString -> IO SResponse
getResponse app path = runSession (request $ setPath defaultRequest path) app

assertGolden :: FilePath -> LBS.ByteString -> Expectation
assertGolden name actual = do
  path <- getDataFileName $ "test/golden/" <> name
  expected <- LBS.readFile path
  actual `shouldBe` expected
