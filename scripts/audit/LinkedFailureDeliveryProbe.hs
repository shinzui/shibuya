{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Diagnostic: under StopAllOnFailure, how many linked-thread exceptions reach
-- the runApp caller for ONE processor failure? The handle is retained throughout,
-- so garbage collection plays no part here.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, throwIO, try)
import Control.Monad (forM)
import Data.IORef (newIORef, readIORef, writeIORef)
import Effectful (liftIO, runEff)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App
  ( AppConfig (..),
    ProcessorId (..),
    SupervisionStrategy (..),
    defaultAppConfig,
    mkProcessor,
    runApp,
    stopApp,
  )
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream
import System.Exit (die)

main :: IO ()
main = do
  keep <- newIORef (pure () :: IO ())
  let adapter =
        Adapter
          { adapterName = "probe:boom",
            source = Stream.fromEffect (liftIO (throwIO (userError "boom"))),
            shutdown = pure ()
          }
  started <- try @SomeException $ runEff $ runTracingNoop $ do
    result <-
      runApp
        defaultAppConfig {strategy = StopAllOnFailure}
        [(ProcessorId "boom", mkProcessor adapter (\_ -> pure AckOk))]
    case result of
      Left err -> liftIO $ die ("runApp failed: " <> show err)
      Right app -> liftIO $ writeIORef keep (runEff (runTracingNoop (stopApp app)))
  -- Six observation windows on the calling thread; count exceptions received.
  windows <- forM [1 :: Int .. 6] $ \_ -> try @SomeException (threadDelay 150_000)
  let received = [displayException e | Left e <- either (pure . Left) (const []) started ++ windows]
  putStrLn ("RESULT deliveries=" <> show (length received))
  mapM_ (putStrLn . ("  " <>)) received
  _ <- try @SomeException (readIORef keep >>= id)
  pure ()
