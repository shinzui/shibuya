module Shibuya.Telemetry.LifecycleSpec (spec) where

import Control.Concurrent (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically, retry)
import Control.Exception (SomeException, bracket, displayException)
import Control.Monad (forM_, void)
import Data.Foldable (toList)
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Exception qualified as Exception
import OpenTelemetry.Attributes (emptyAttributes, getAttributeMap, toAttribute)
import OpenTelemetry.Exporter.InMemory (inMemoryListExporter)
import OpenTelemetry.Trace.Core qualified as OTel
import OpenTelemetry.Util (appendOnlyBoundedCollectionValues)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Mock (listAdapter)
import Shibuya.App
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Internal.Runner.Master (ProcessorLifecycle (..), getLifecycleSnapshot)
import Shibuya.Telemetry.Effect (Tracing, runTracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import UnliftIO qualified as UIO

spec :: Spec
spec = describe "Shibuya.Telemetry.Lifecycle" $ do
  forM_ [False, True] $ \batching ->
    it ("emits one ingestion lifetime and once-only shutdown for " <> if batching then "batch" else "single") $ do
      calls <- newIORef (0 :: Int)
      (_, spans) <- withExporter $ \tracer -> runEff $ runTracing tracer $ do
        let messages = [mkIngested (mkEnvelope (MessageId "one") ()) (AckHandle (const $ pure ()))]
            adapter = (listAdapter messages) {shutdown = liftIO $ modifyIORef' calls (+ 1)}
            processor =
              if batching
                then mkBatchProcessor adapter (\_ _ -> pure ackAllOk) defaultBatchConfig
                else mkProcessor adapter (const $ pure AckOk)
        app <- start processor
        Exception.finally (waitApp app) (stopApp app)
        stopApp app
      readIORef calls `shouldReturn` 1
      expectSpan "shibuya.ingest" spans >>= expectIdentity
      expectSpan "lifecycle shutdown" spans >>= expectIdentity

  it "records source failure and retains the terminal lifecycle" $ do
    (state, spans) <- withExporter $ \tracer -> runEff $ runTracing tracer $ do
      let adapter = (listAdapter []) {source = Stream.repeatM (Exception.throwIO $ userError "source failed")}
      app <- start $ mkProcessor adapter (const $ pure AckOk)
      Exception.finally
        (waitApp app >> getLifecycleSnapshot (getAppMaster app))
        (stopApp app)
    case Map.lookup (ProcessorId "lifecycle") state of
      Just (LifecycleFailed message _) -> message `shouldSatisfy` (Text.isInfixOf "source failed")
      _ -> expectationFailure $ "expected source failure, got " <> show state
    expectSpan "shibuya.ingest" spans >>= expectError

  it "records a shutdown exception, preserves it, and caches it" $ do
    calls <- newIORef (0 :: Int)
    (results, spans) <- withExporter $ \tracer -> runEff $ runTracing tracer $ do
      let adapter = (listAdapter []) {shutdown = liftIO (modifyIORef' calls (+ 1)) >> Exception.throwIO (userError "shutdown failed")}
      app <- start $ mkProcessor adapter (const $ pure AckOk)
      waitApp app
      first <- Exception.try @SomeException $ stopApp app
      second <- Exception.try @SomeException $ stopApp app
      pure [first, second]
    forM_ results $ \result -> case result of
      Left failure -> displayException failure `shouldContain` "shutdown failed"
      Right () -> expectationFailure "shutdown exception disappeared"
    readIORef calls `shouldReturn` 1
    expectSpan "lifecycle shutdown" spans >>= expectError

  it "records shutdown deadline cancellation without changing the False result" $ do
    ((first, second), spans) <- withExporter $ \tracer -> runEff $ runTracing tracer $ do
      let adapter = (listAdapter []) {shutdown = liftIO $ atomically retry}
      app <- start $ mkProcessor adapter (const $ pure AckOk)
      waitApp app
      first <- stopAppGracefully defaultShutdownConfig {totalShutdownTimeout = 0.05} app
      second <- stopAppGracefully defaultShutdownConfig app
      pure (first, second)
    (first, second) `shouldBe` (False, False)
    expectSpan "lifecycle shutdown" spans >>= expectError

  it "exports cancellation of the ingester when the master is force-stopped" $ do
    started <- newEmptyMVar
    (drained, spans) <- withExporter $ \tracer -> runEff $ runTracing tracer $ do
      let adapter =
            (listAdapter [])
              { source = Stream.repeatM (liftIO (putMVar started () >> atomically retry))
              }
      app <- start $ mkProcessor adapter (const $ pure AckOk)
      liftIO $ takeMVar started
      stopAppGracefully defaultShutdownConfig {drainTimeout = 0.05, totalShutdownTimeout = 1} app
    drained `shouldBe` False
    expectSpan "shibuya.ingest" spans >>= expectError

  it "uses the startup tracer even if stop runs under a different runner" $ do
    (_, spans) <- withExporter $ \tracer -> do
      app <- runEff $ runTracing tracer $ do
        app <- start $ mkProcessor (listAdapter []) (const $ pure AckOk)
        waitApp app
        pure app
      runEff $ runTracingNoop $ stopApp app
    expectSpan "lifecycle shutdown" spans >>= expectIdentity

  it "exports no lifecycle spans with tracing disabled" $ do
    (_, spans) <- withExporter $ \_ -> runEff $ runTracingNoop $ do
      app <- start $ mkProcessor (listAdapter []) (const $ pure AckOk)
      waitApp app
      stopApp app
    length spans `shouldBe` 0

start :: (IOE :> es, Tracing :> es) => QueueProcessor es -> Eff es (AppHandle es)
start processor =
  runApp defaultAppConfig [(ProcessorId "lifecycle", processor)] >>= \case
    Left err -> liftIO $ expectationFailure (show err) >> error "unreachable"
    Right app -> pure app

withExporter :: (OTel.Tracer -> IO a) -> IO (a, [OTel.ImmutableSpan])
withExporter action = do
  (processor, spansRef) <- inMemoryListExporter
  result <- bracket
    (OTel.createTracerProvider [processor] OTel.emptyTracerProviderOptions)
    (\p -> void $ OTel.shutdownTracerProvider p (Just 5_000_000))
    $ \provider -> do
      let tracer = OTel.makeTracer provider (OTel.InstrumentationLibrary "lifecycle-test" "" "" emptyAttributes) OTel.tracerOptions
      -- Bound every test, including waits, so a lifecycle regression cannot hang.
      UIO.timeout 5_000_000 (action tracer) >>= \case
        Nothing -> expectationFailure "lifecycle test timed out" >> error "unreachable"
        Just value -> pure value
  spans <- readIORef spansRef
  pure (result, spans)

expectSpan :: Text -> [OTel.ImmutableSpan] -> IO OTel.ImmutableSpan
expectSpan name spans = do
  named <- mapM (\sp -> do hot <- readIORef (OTel.spanHot sp); pure (OTel.hotName hot, sp)) spans
  case [sp | (n, sp) <- named, n == name] of
    [sp] -> pure sp
    matches -> expectationFailure ("expected one " <> show name <> " span; got " <> show (length matches)) >> error "unreachable"

expectIdentity :: OTel.ImmutableSpan -> Expectation
expectIdentity sp = do
  OTel.spanKind sp `shouldBe` OTel.Internal
  hot <- readIORef (OTel.spanHot sp)
  HashMap.lookup "shibuya.processor.id" (getAttributeMap (OTel.hotAttributes hot))
    `shouldBe` Just (toAttribute ("lifecycle" :: Text))

expectError :: OTel.ImmutableSpan -> Expectation
expectError sp = do
  expectIdentity sp
  hot <- readIORef (OTel.spanHot sp)
  OTel.hotStatus hot `shouldSatisfy` (\case OTel.Error _ -> True; _ -> False)
  map OTel.eventName (toList $ appendOnlyBoundedCollectionValues $ OTel.hotEvents hot)
    `shouldContain` ["exception"]
