module Shibuya.Metrics.ControlSpec (spec) where

import Control.Concurrent.STM
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson (Value (..), decode, eitherDecode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types
import Network.Wai (Application, requestHeaders, requestMethod)
import Network.Wai.Handler.Warp qualified as Warp
import Network.Wai.Test
import Network.WebSockets qualified as WS
import Shibuya qualified as Public
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Metrics
import Shibuya.Internal.Runner.Master
import Shibuya.Internal.Runner.Pause
import Shibuya.Metrics.Config
import Shibuya.Metrics.Server (combinedApp)
import Shibuya.Metrics.TestSupport (fixedTime, registerIdleProcessor, withMaster)
import Shibuya.Metrics.Types (ServerMessage (..))
import Shibuya.Metrics.WebSocket (newWebSocketState)
import Streamly.Data.Stream qualified as Stream
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  around withMaster $ describe "gated control routes" $ do
    it "discovers both gate positions and refuses disabled mutations" $ \master -> do
      _ <- controllableFixture master
      forM_ [False, True] $ \enabled -> do
        app <- application defaultConfig {enableControl = enabled} master
        response <- send app methodGet "/control" []
        response.simpleStatus `shouldBe` status200
        decode response.simpleBody `shouldBe` Just (object ["enabled" .= enabled, "operations" .= (["pause", "resume"] :: [String])])
      app <- application defaultConfig master
      forM_ ["pause", "resume"] $ \op -> do
        response <- send app methodPost ("/control/processors/orders/" <> op) [("Origin", "https://forbidden.example")]
        assertCode response status403 "control_disabled"
        isProcessorPausedIO master (ProcessorId "orders") `shouldReturn` Just False

    it "makes repeated pause and resume idempotent with an unchanged pause timestamp" $ \master -> do
      _ <- controllableFixture master
      app <- application defaultConfig {enableControl = True} master
      first <- send app methodPost "/control/processors/orders/pause" []
      second <- send app methodPost "/control/processors/orders/pause" []
      first.simpleStatus `shouldBe` status200
      first.simpleBody `shouldBe` second.simpleBody
      field "state" first `shouldBe` Just (String "paused")
      field "pausedAt" first `shouldSatisfy` maybe False (const True)
      isProcessorPausedIO master (ProcessorId "orders") `shouldReturn` Just True
      forM_ [1, 2 :: Int] $ \_ -> do
        response <- send app methodPost "/control/processors/orders/resume" []
        decode response.simpleBody `shouldBe` Just (object ["processor" .= ("orders" :: String), "state" .= ("running" :: String)])
        isProcessorPausedIO master (ProcessorId "orders") `shouldReturn` Just False

    it "maps unknown, uncontrollable, terminal and draining outcomes" $ \master -> do
      (_, pause) <- controllableFixture master
      _ <- registerIdleProcessor master (ProcessorId "fixture")
      app <- application defaultConfig {enableControl = True} master
      send app methodPost "/control/processors/missing/pause" [] >>= \r -> assertCode r status404 "processor_not_found"
      send app methodPost "/control/processors/fixture/pause" [] >>= \r -> assertCode r status409 "processor_not_controllable"
      runEff $ drainAndResume master
      send app methodPost "/control/processors/orders/pause" [] >>= \r -> assertCode r status409 "processor_draining"
      isPaused pause `shouldReturn` False
      markProcessorFailedIO master (ProcessorId "orders") "failure" Nothing
      runEff $ unregisterProcessor master (ProcessorId "orders")
      send app methodPost "/control/processors/orders/resume" [] >>= \r -> assertCode r status409 "processor_terminal"

    it "does not confuse cold Failed observation with terminal lifecycle" $ \master -> do
      (h, _) <- controllableFixture master
      finishProcessing h (Left "transient")
      app <- application defaultConfig {enableControl = True} master
      response <- send app methodPost "/control/processors/orders/pause" []
      response.simpleStatus `shouldBe` status200
      isProcessorPausedIO master (ProcessorId "orders") `shouldReturn` Just True

    it "checks methods, unknown paths and the JSON enable flag" $ \master -> do
      app <- application defaultConfig {enableControl = True} master
      forM_ [(methodDelete, "/control", "GET"), (methodGet, "/control/processors/orders/pause", "POST")] $ \(method, path, allowed) -> do
        response <- send app method path []
        assertCode response status405 "method_not_allowed"
        lookup "Allow" response.simpleHeaders `shouldBe` Just allowed
      send app methodGet "/control/other" [] >>= \r -> assertCode r status404 "not_found"
      hidden <- application defaultConfig {enableJSON = False, enableControl = True} master
      send hidden methodPost "/control/processors/orders/pause" [] >>= \r -> assertCode r status404 "not_found"
      send hidden methodGet "/control" [] >>= \r -> assertCode r status404 "not_found"

    it "refuses forbidden and repeated Origins before a bodyless or simple POST can mutate" $ \master -> do
      _ <- controllableFixture master
      forM_ [[], ["https://ops.example.com"]] $ \origins -> do
        app <- application defaultConfig {enableControl = True, corsAllowedOrigins = origins} master
        forM_ [[("Origin", "https://evil.example")], [("Origin", "null")], [("Origin", "")], [("Origin", "https://ops.example.com"), ("Origin", "https://ops.example.com")]] $ \headers ->
          forM_ [[], [("Content-Type", "text/plain")]] $ \content -> do
            response <- send app methodPost "/control/processors/orders/pause" (headers ++ content)
            assertCode response status403 "origin_not_allowed"
            isProcessorPausedIO master (ProcessorId "orders") `shouldReturn` Just False
      app <- application defaultConfig {enableControl = True, corsAllowedOrigins = ["https://ops.example.com"]} master
      response <- send app methodPost "/control/processors/orders/pause" [("Origin", "https://ops.example.com")]
      response.simpleStatus `shouldBe` status200
      isProcessorPausedIO master (ProcessorId "orders") `shouldReturn` Just True

    it "serves the allowed-origin action preflight" $ \master -> do
      app <- application defaultConfig {enableControl = True, corsAllowedOrigins = ["https://ops.example.com"]} master
      response <- send app methodOptions "/control/processors/orders/pause" [("Origin", "https://ops.example.com"), ("Access-Control-Request-Method", "POST")]
      response.simpleStatus `shouldBe` status204
      lookup "Access-Control-Allow-Origin" response.simpleHeaders `shouldBe` Just "https://ops.example.com"
      lookup "Access-Control-Allow-Methods" response.simpleHeaders `shouldBe` Just "GET, POST, OPTIONS"

  describe "real HTTP and WebSocket control" $
    it "pauses admission, drains an admitted message, observes paused state, resumes and shuts down" $ do
      polls <- newTQueueIO
      releases <- newTQueueIO
      started <- newTQueueIO
      handlerGate <- newEmptyTMVarIO
      finalized <- newTVarIO (0 :: Int)
      stopped <- newTVarIO False
      let acquire = runEff $ Public.runTracingNoop $ do
            let source =
                  Stream.unfoldrM
                    ( \n -> do
                        liftIO $ atomically $ writeTQueue polls n
                        next <-
                          liftIO $
                            atomically $
                              (readTVar stopped >>= check >> pure Nothing) `orElse` (Just <$> readTQueue releases)
                        pure $ fmap (\() -> (Public.mkIngested (Public.mkEnvelope (Public.MessageId "live") ()) (Public.AckHandle (\_ -> liftIO $ atomically $ modifyTVar' finalized (+ 1))), n + 1)) next
                    )
                    (1 :: Int)
                adapter = Adapter "live" source (liftIO $ atomically $ writeTVar stopped True)
                handler _ = do
                  liftIO $ atomically $ writeTQueue started ()
                  liftIO $ atomically $ takeTMVar handlerGate
                  pure Public.AckOk
            result <- Public.runApp Public.defaultAppConfig [(ProcessorId "orders", Public.mkProcessor adapter handler)]
            either (liftIO . ioError . userError . show) pure result
          release app = runEff $ Public.runTracingNoop $ Public.stopAppGracefully Public.defaultShutdownConfig app
      bracket acquire release $ \app -> do
        bounded (atomically $ readTQueue polls) `shouldReturn` 1
        let master = Public.getAppMaster app
        server <- application defaultConfig {enableControl = True, wsPushIntervalUs = 10_000} master
        Warp.testWithApplication (pure server) $ \port -> do
          manager <- HTTP.newManager HTTP.defaultManagerSettings
          WS.runClient "127.0.0.1" port "/ws" $ \connection -> do
            _ <- bounded $ WS.receiveData @LBS.ByteString connection
            let post operation = HTTP.httpLbs (HTTP.parseRequest_ ("http://127.0.0.1:" <> show port <> "/control/processors/orders/" <> operation)) {HTTP.method = methodPost} manager
            pause <- post "pause"
            HTTP.responseStatus pause `shouldBe` status200
            atomically $ writeTQueue releases ()
            bounded $ atomically $ readTQueue started
            observePaused connection
            atomically $ putTMVar handlerGate ()
            bounded $ atomically $ readTVar finalized >>= check . (== 1)
            timeout 100_000 (atomically $ readTQueue polls) `shouldReturn` Nothing
            metric <- HTTP.httpLbs (HTTP.parseRequest_ ("http://127.0.0.1:" <> show port <> "/metrics/orders")) manager
            case eitherDecode (HTTP.responseBody metric) of
              Right m -> (m :: ProcessorMetrics).state `shouldSatisfy` (\case Paused {} -> True; _ -> False)
              Left err -> expectationFailure err
            resumed <- post "resume"
            HTTP.responseStatus resumed `shouldBe` status200
            bounded (atomically $ readTQueue polls) `shouldReturn` 2
            atomically $ writeTQueue releases ()
            bounded $ atomically $ readTQueue started
            atomically $ putTMVar handlerGate ()
            bounded $ atomically $ readTVar finalized >>= check . (== 2)
            pure ()

application :: MetricsServerConfig -> Master -> IO Application
application config master = do
  state <- newWebSocketState config.wsMaxConnections
  pure $ combinedApp config master state []

controllableFixture :: Master -> IO (MetricsHandle, PauseHandle)
controllableFixture master = do
  h <- newMetricsHandle fixedTime
  pause <- newPauseHandle
  runEff $ registerProcessorWithPause master (ProcessorId "orders") h (Just pause)
  pure (h, pause)

send :: Application -> Method -> ByteString -> RequestHeaders -> IO SResponse
send app method path headers = runSession (request $ setPath defaultRequest {requestMethod = method, requestHeaders = headers} path) app

field :: Key.Key -> SResponse -> Maybe Value
field key response = case decode response.simpleBody of
  Just (Object values) -> KM.lookup key values
  _ -> Nothing

assertCode :: SResponse -> Status -> String -> Expectation
assertCode response status code = do
  response.simpleStatus `shouldBe` status
  field "code" response `shouldBe` Just (String (Text.pack code))

observePaused :: WS.Connection -> IO ()
observePaused connection = bounded loop
  where
    loop = do
      bytes <- WS.receiveData connection
      case eitherDecode bytes of
        Right (ProcessorUpdate _ metrics) | Paused {} <- metrics.state -> pure ()
        Right (_ :: ServerMessage) -> loop
        Left err -> expectationFailure err

bounded :: IO a -> IO a
bounded action = timeout 2_000_000 action >>= maybe (expectationFailure "timed out" >> error "timeout") pure
