-- | __Internal module.__ Exposed for the test suite and benchmarks only.
-- No PVP guarantees: anything here may change or disappear in any release.
-- Application authors should import "Shibuya" instead.
--
-- Halt exception for processor termination.
-- Thrown when a handler returns AckHalt to stop processing.
module Shibuya.Internal.Runner.Halt
  ( ProcessorHalt (..),
    ProcessorFailure (..),
    ProcessorExit (..),
    ProcessorSignal,
    ProcessorExitPublisher,
    newProcessorSignal,
    newProcessorExitPublisher,
    newProcessorExitPublisherWithWake,
    readProcessorExit,
    requestProcessorExit,
    throwProcessorExit,
  )
where

import Control.Concurrent.STM (TVar, atomically, writeTVar)
import Control.Exception (Exception, mask_)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Shibuya.Core.Ack (HaltReason)
import Shibuya.Core.Types (MessageId)
import Shibuya.Prelude
import UnliftIO (throwIO)

-- | Exception thrown when processing should halt.
-- The supervisor catches this to handle graceful shutdown.
data ProcessorHalt = ProcessorHalt
  { reason :: !HaltReason
  }
  deriving stock (Show, Generic)

instance Exception ProcessorHalt

-- | An infrastructure failure that must remain distinguishable from a handler's
-- deliberate 'AckHalt'. The optional message identity is retained when the
-- failure occurred while finalizing a delivery.
data ProcessorFailure = ProcessorFailure !Text !(Maybe MessageId)
  deriving stock (Show, Generic)

instance Exception ProcessorFailure

-- | The first terminal request observed by a processor. Infrastructure failure
-- takes precedence over a graceful halt if concurrent work reports both.
data ProcessorExit
  = ProcessorHalted !HaltReason
  | ProcessorFailed !Text !(Maybe MessageId)
  deriving stock (Eq, Show, Generic)

-- | A cheap hot-path stop observation. The corresponding publisher is kept
-- separate so message actions retain one opaque cold-path pointer rather than
-- capturing and field-splitting the signal and its STM wake cell.
newtype ProcessorSignal = ProcessorSignal
  { terminalExit :: IORef (Maybe ProcessorExit)
  }

-- | Opaque cold-path terminal publisher. The function closure may retain both
-- the signal and an intake wake cell, but hot message closures retain only this
-- single pointer. The box prevents GHC from field-splitting those two captured
-- cells back into every nested per-message closure.
data ProcessorExitPublisher = ProcessorExitPublisher (ProcessorExit -> IO ())

newProcessorSignal :: IO ProcessorSignal
newProcessorSignal = ProcessorSignal <$> newIORef Nothing

newProcessorExitPublisher :: ProcessorSignal -> ProcessorExitPublisher
newProcessorExitPublisher signal =
  ProcessorExitPublisher $ \requested ->
    mask_ $ publishProcessorExit signal requested
{-# OPAQUE newProcessorExitPublisher #-}

newProcessorExitPublisherWithWake :: ProcessorSignal -> TVar Bool -> ProcessorExitPublisher
newProcessorExitPublisherWithWake signal intakeWake =
  ProcessorExitPublisher $ \requested ->
    -- Publish the terminal outcome before the STM wakeup. Masking prevents
    -- cancellation from leaving only the outcome set; this path runs once per
    -- terminal request, not once per message.
    mask_ $ do
      publishProcessorExit signal requested
      atomically $ writeTVar intakeWake True
{-# OPAQUE newProcessorExitPublisherWithWake #-}

readProcessorExit :: ProcessorSignal -> IO (Maybe ProcessorExit)
readProcessorExit = readIORef . (.terminalExit)
{-# INLINE readProcessorExit #-}

requestProcessorExit :: ProcessorExitPublisher -> ProcessorExit -> IO ()
requestProcessorExit (ProcessorExitPublisher publish) = publish
{-# OPAQUE requestProcessorExit #-}

publishProcessorExit :: ProcessorSignal -> ProcessorExit -> IO ()
publishProcessorExit signal requested =
  atomicModifyIORef' signal.terminalExit $ \current ->
    ( case (current, requested) of
        (Just ProcessorFailed {}, _) -> current
        (_, ProcessorFailed {}) -> Just requested
        (Nothing, _) -> Just requested
        (Just ProcessorHalted {}, ProcessorHalted {}) -> current,
      ()
    )

throwProcessorExit :: ProcessorExit -> IO a
throwProcessorExit (ProcessorHalted reason) = throwIO (ProcessorHalt reason)
throwProcessorExit (ProcessorFailed failure messageId) =
  throwIO (ProcessorFailure failure messageId)
