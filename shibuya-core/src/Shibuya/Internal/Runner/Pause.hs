-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
module Shibuya.Internal.Runner.Pause
  ( PauseHandle (..),
    newPauseHandle,
    requestPause,
    requestResume,
    requestPauseSTM,
    requestResumeSTM,
    isPaused,
    waitWhilePaused,
  )
where

import Control.Concurrent.STM
import Data.Maybe (isJust)
import Data.Time.Clock (UTCTime, getCurrentTime)

-- | One cell publishes intake intent and the original pause timestamp together.
newtype PauseHandle = PauseHandle {pauseState :: TVar (Maybe UTCTime)}

newPauseHandle :: IO PauseHandle
newPauseHandle = PauseHandle <$> newTVarIO Nothing

requestPause :: PauseHandle -> IO Bool
requestPause handle = getCurrentTime >>= atomically . requestPauseSTM handle

requestPauseSTM :: PauseHandle -> UTCTime -> STM Bool
requestPauseSTM handle now =
  readTVar handle.pauseState >>= \case
    Just _ -> pure False
    Nothing -> writeTVar handle.pauseState (Just now) >> pure True

requestResume :: PauseHandle -> IO Bool
requestResume = atomically . requestResumeSTM

requestResumeSTM :: PauseHandle -> STM Bool
requestResumeSTM handle = do
  previous <- readTVar handle.pauseState
  writeTVar handle.pauseState Nothing
  pure (isJust previous)

isPaused :: PauseHandle -> IO Bool
isPaused handle = isJust <$> readTVarIO handle.pauseState

-- | Admission check only. An already admitted poll cannot be revoked.
-- The running path reads once; a paused wait is interruptible by cancellation.
waitWhilePaused :: PauseHandle -> IO ()
waitWhilePaused handle = do
  paused <- isPaused handle
  if paused
    then atomically $ readTVar handle.pauseState >>= maybe (pure ()) (const retry)
    else pure ()
