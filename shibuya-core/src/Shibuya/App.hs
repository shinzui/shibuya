-- | Application entry point.
-- Where Streamly wiring, supervision, ack lifecycle, and halt semantics are applied.
module Shibuya.App
  ( runApp,
    AppError (..),
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Policy (Concurrency (..), validatePolicy)
import Shibuya.Runner (RunnerConfig (..))
import Shibuya.Runner.Serial (runSerial)
import UnliftIO (SomeException, catch, displayException)
import Prelude hiding (Ordering)

-- | Application errors.
data AppError
  = -- | Invalid policy configuration
    PolicyValidationError !Text
  | -- | Adapter error
    AdapterError !Text
  | -- | Handler error
    HandlerError !Text
  | -- | Runtime error
    RuntimeError !Text
  deriving stock (Eq, Show)

-- | Run the message processing application.
-- This is the main entry point for running a Shibuya application.
runApp ::
  (IOE :> es) =>
  RunnerConfig es msg ->
  Eff es (Either AppError ())
runApp config = do
  -- Validate policy
  case validatePolicy config.ordering config.concurrency of
    Left err -> pure $ Left $ PolicyValidationError err
    Right () -> runWithRunner config

-- | Run with the appropriate runner based on concurrency config.
runWithRunner ::
  (IOE :> es) =>
  RunnerConfig es msg ->
  Eff es (Either AppError ())
runWithRunner config = do
  let size = fromIntegral config.inboxSize

  -- Dispatch to appropriate runner based on concurrency mode
  result <-
    catch
      ( case config.concurrency of
          Serial -> do
            runSerial size config.adapter config.handler
            pure $ Right ()
          Ahead _n -> do
            -- TODO: Implement ahead-of-time prefetch runner
            runSerial size config.adapter config.handler
            pure $ Right ()
          Async _n -> do
            -- TODO: Implement async concurrent runner
            runSerial size config.adapter config.handler
            pure $ Right ()
      )
      ( \(e :: SomeException) ->
          pure $ Left $ RuntimeError $ Text.pack $ displayException e
      )

  -- Call adapter shutdown
  config.adapter.shutdown

  pure result
