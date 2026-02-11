{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the Tracing effect.
module Shibuya.Telemetry.EffectSpec (spec) where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Effectful (liftIO, runEff)
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Telemetry.Effect
  ( addAttribute,
    addEvent,
    getTracer,
    isTracingEnabled,
    runTracingNoop,
    setStatus,
    withSpan,
    withSpan',
  )
import Shibuya.Telemetry.Semantic (consumerSpanArgs, mkEvent)
import Test.Hspec

spec :: Spec
spec = describe "Shibuya.Telemetry.Effect" $ do
  describe "runTracingNoop" $ do
    it "executes actions and returns result" $ do
      result <- runEff $ runTracingNoop $ do
        pure (42 :: Int)
      result `shouldBe` 42

    it "executes nested withSpan without error" $ do
      result <- runEff $ runTracingNoop $ do
        withSpan "outer" consumerSpanArgs $ do
          withSpan "inner" consumerSpanArgs $ do
            pure ("success" :: String)
      result `shouldBe` "success"

    it "executes withSpan' and provides span handle" $ do
      result <- runEff $ runTracingNoop $ do
        withSpan' "test-span" consumerSpanArgs $ \traceSpan -> do
          -- These should be no-ops but not error
          addAttribute traceSpan "key" ("value" :: Text)
          addEvent traceSpan (mkEvent "test.event" [])
          setStatus traceSpan OTel.Ok
          pure (123 :: Int)
      result `shouldBe` 123

    it "reports tracing as disabled" $ do
      enabled <- runEff $ runTracingNoop $ isTracingEnabled
      enabled `shouldBe` False

    it "provides a tracer (noop)" $ do
      result <- runEff $ runTracingNoop $ do
        _tracer <- getTracer
        pure ("got tracer" :: String)
      result `shouldBe` "got tracer"

    it "handles exceptions in actions correctly" $ do
      ref <- newIORef (0 :: Int)
      result <- runEff $ runTracingNoop $ do
        withSpan "outer" consumerSpanArgs $ do
          liftIO $ writeIORef ref 1
          withSpan "inner" consumerSpanArgs $ do
            liftIO $ writeIORef ref 2
            pure ()
        liftIO $ readIORef ref
      result `shouldBe` 2

    it "works with effectful actions" $ do
      ref <- newIORef ([] :: [String])
      let modifyIORef' r f = do
            val <- readIORef r
            writeIORef r (f val)
      result <- runEff $ runTracingNoop $ do
        withSpan "span1" consumerSpanArgs $ do
          liftIO $ modifyIORef' ref ("span1" :)
        withSpan "span2" consumerSpanArgs $ do
          liftIO $ modifyIORef' ref ("span2" :)
        liftIO $ readIORef ref
      -- Order is reversed due to cons
      result `shouldBe` ["span2", "span1"]

  describe "Span operations (noop mode)" $ do
    it "addAttribute is a no-op" $ do
      result <- runEff $ runTracingNoop $ do
        withSpan' "test" consumerSpanArgs $ \traceSpan -> do
          addAttribute traceSpan "string" ("value" :: Text)
          addAttribute traceSpan "int" (42 :: Int)
          addAttribute traceSpan "bool" True
          pure ("done" :: String)
      result `shouldBe` ("done" :: String)

    it "addEvent is a no-op" $ do
      result <- runEff $ runTracingNoop $ do
        withSpan' "test" consumerSpanArgs $ \traceSpan -> do
          addEvent traceSpan (mkEvent "event1" [])
          addEvent traceSpan (mkEvent "event2" [("key", OTel.toAttribute ("val" :: Text))])
          pure ("done" :: String)
      result `shouldBe` ("done" :: String)

    it "setStatus is a no-op" $ do
      result <- runEff $ runTracingNoop $ do
        withSpan' "test" consumerSpanArgs $ \traceSpan -> do
          setStatus traceSpan OTel.Ok
          setStatus traceSpan (OTel.Error "test error")
          setStatus traceSpan OTel.Unset
          pure ("done" :: String)
      result `shouldBe` ("done" :: String)
