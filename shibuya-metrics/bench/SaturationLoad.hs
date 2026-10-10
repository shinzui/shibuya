-- | Deterministic saturation with a real connection and a blocked writer hook.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (IgnoreAll))
import Control.Concurrent.STM
  ( atomically,
    check,
    newTQueueIO,
    newTVarIO,
    orElse,
    readTQueue,
    readTVar,
    writeTQueue,
    writeTVar,
  )
import Control.Exception (bracket)
import Control.Monad (replicateM, when)
import Data.Aeson (encode, object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Effectful (runEff)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Stats (GCDetails (..), RTSStats (..), getRTSStats)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Handler.WebSockets qualified as WaiWS
import Network.WebSockets qualified as WS
import Shibuya.Core.Metrics (ProcessorId (..), incrementReceived, newMetricsHandle)
import Shibuya.Internal.Runner.Master (markMasterRunning, registerProcessor, startMaster, stopMaster)
import Shibuya.Metrics.Config (MetricsServerConfig (..), defaultConfig)
import Shibuya.Metrics.Outbound qualified as Out
import Shibuya.Metrics.Server (combinedApp)
import Shibuya.Metrics.WebSocket
  ( WebSocketHooks (..),
    WebSocketState (..),
    defaultWebSocketHooks,
    newWebSocketState,
    websocketAppWithHooks,
  )
import System.Environment (lookupEnv)
import System.Mem (performMajorGC)
import System.Timeout (timeout)

main :: IO ()
main = bracket acquire (runEff . stopMaster) $ \master -> do
  handle <- getCurrentTime >>= newMetricsHandle
  runEff $ registerProcessor master (ProcessorId $ Text.replicate 8192 "p") handle
  gate <- newTVarIO False
  entered <- newTQueueIO
  ticks <- newTQueueIO
  observed <- newTQueueIO
  state <- newWebSocketState 1
  let config = defaultConfig {wsMaxQueuedBytes = 65_536, wsSendTimeoutUs = 1_000_000}
      hooks =
        defaultWebSocketHooks
          { beforeWrite = \_ -> do
              atomically $ readTVar gate >>= \blocked -> when blocked (writeTQueue entered ())
              atomically $ readTVar gate >>= check . not,
            afterProduce = atomically . writeTQueue observed,
            waitForPush = \_ wsState ->
              atomically $
                (readTVar wsState.shutdownRequested >>= \stopped -> check stopped >> pure True)
                  `orElse` (readTQueue ticks >> pure False)
          }
      app =
        WaiWS.websocketsOr
          WS.defaultConnectionOptions
          (websocketAppWithHooks hooks config master state)
          (combinedApp config {enableWebSocket = False} master state [])
      tick =
        incrementReceived handle
          >> atomically (writeTQueue ticks ())
          >> timeout 50_000 (atomically $ readTQueue observed)
      fill n previous = do
        result <- tick
        case result of
          Nothing -> pure (n, previous)
          Just q -> do
            when (Out.queuedFrames q > config.wsMaxQueuedFrames || Out.queuedBytes q > config.wsMaxQueuedBytes) $
              fail "queue exceeded a budget"
            if n >= (500 :: Int) then fail "required saturation never stopped production" else fill (n + 1) q
  report <- Warp.testWithApplication (pure app) $ \port ->
    WS.runClient "127.0.0.1" port "/ws" $ \conn -> do
      _ <- WS.receiveData conn :: IO LBS.ByteString
      atomically $ writeTVar gate True
      _ <- tick
      blocked <- timeout 500_000 $ atomically $ readTQueue entered
      when (blocked /= Just ()) $ fail "writer was not blocked"
      (count, q) <- fill 1 Out.empty
      heap <- replicateM 4 $ do
        performMajorGC
        stats <- getRTSStats
        threadDelay 20_000
        pure stats.gc.gcdetails_live_bytes
      started <- getMonotonicTimeNSec
      released <- timeout 1_500_000 $ atomically $ readTVar state.connectionCount >>= check . (== 0)
      ended <- getMonotonicTimeNSec
      when (released /= Just ()) $ fail "stalled connection slot was not released"
      pure $
        object
          [ "schemaVersion" .= (1 :: Int),
            "producerTicksBeforeSaturation" .= count,
            "frameBudget" .= config.wsMaxQueuedFrames,
            "byteBudget" .= config.wsMaxQueuedBytes,
            "retainedFramesAtSaturation" .= Out.queuedFrames q,
            "retainedEncodedBytesAtSaturation" .= Out.queuedBytes q,
            "liveHeapSamplesAfterSaturation" .= heap,
            "slotRecoveryMicros" .= ((ended - started) `div` 1000),
            "finalWebSocketConnections" .= (0 :: Int)
          ]
  path <- maybe "saturation-load.json" id <$> lookupEnv "OUTPUT_JSON"
  LBS.writeFile path $ encode report <> "\n"
  LBS.putStr $ encode report <> "\n"
  where
    acquire = runEff $ do
      master <- startMaster IgnoreAll
      markMasterRunning master
      pure master
