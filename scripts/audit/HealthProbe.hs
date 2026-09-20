{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (threadDelay)
import Data.Time.Clock (getCurrentTime)
import Effectful
import Shibuya.Adapter
import Shibuya.App
import Shibuya.Core.Ack
import Shibuya.Core.Metrics
import Shibuya.Internal.Runner.Master (registerProcessor, stopMaster)
import Shibuya.Metrics.Health
import Shibuya.Telemetry.Effect
import Streamly.Data.Stream qualified as Stream
import UnliftIO qualified as U

main :: IO ()
main = runEff $ runTracingNoop $ do
  let adapter :: Adapter '[Tracing, IOE] ()
      adapter = Adapter "failed-source" (Stream.repeatM (U.throwIO $ userError "source failed")) (pure ())
  app <- runApp defaultAppConfig [(ProcessorId "failed", mkProcessor adapter (const $ pure AckOk))] >>= either (U.throwIO . userError . show) pure
  waitApp app
  readiness <- liftIO $ checkReadiness defaultHealthConfig (getAppMaster app) []
  liftIO $ putStrLn $ "after source failure: " <> show readiness
  stopMaster (getAppMaster app)
  liveness <- liftIO $ checkLiveness defaultHealthConfig (getAppMaster app)
  liftIO $ putStrLn $ "after master stop: " <> show liveness

  fresh <- runApp defaultAppConfig [] >>= either (U.throwIO . userError . show) pure
  now <- liftIO getCurrentTime
  handle <- liftIO $ newMetricsHandle now
  registerProcessor (getAppMaster fresh) (ProcessorId "bursts") handle
  _ <- liftIO $ beginProcessing handle 1
  liftIO $ finishProcessing handle (Right CountProcessed)
  liftIO $ threadDelay 100000
  _ <- liftIO $ beginProcessing handle 1
  second <- liftIO $ checkReadiness (defaultHealthConfig {stuckThreshold = 0.05}) (getAppMaster fresh) []
  liftIO $ putStrLn $ "immediately after second burst starts: " <> show second
  liftIO $ finishProcessing handle (Right CountProcessed)
  stopMaster (getAppMaster fresh)
