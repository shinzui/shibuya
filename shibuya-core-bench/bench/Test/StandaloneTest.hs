-- | Standalone test to debug STM blocking issue
module Main where

import Control.Concurrent (threadDelay)
import Control.Concurrent.NQE.Supervisor (Strategy (..))
import Control.DeepSeq (NFData)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import GHC.Generics (Generic)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..))
import Shibuya.Runner.Master (startMaster, stopMaster)
import Shibuya.Runner.Metrics (ProcessorId (..))
import Shibuya.Runner.Supervised (runSupervised)
import Shibuya.Telemetry.Effect (runTracingNoop)
import Streamly.Data.Stream qualified as Stream

-- | Simple message type
data BenchMessage = BenchMessage
  { msgId :: !Int,
    msgPayload :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (NFData)

main :: IO ()
main = do
  putStrLn "Starting standalone test..."

  -- Run multiple times to test for race conditions
  results <- mapM runOnce [1 .. 10]

  putStrLn $ "Results: " ++ show results
  putStrLn "All done!"

runOnce :: Int -> IO Int
runOnce iteration = do
  putStrLn $ "Iteration " ++ show iteration ++ " (Async 5)..."
  result <- runWithConcurrency (Async 5) (ioBoundHandler 1000) 100
  putStrLn $ "  Processed: " ++ show result
  pure result

-- | IO-bound handler for testing async
ioBoundHandler :: (IOE :> es) => Int -> IORef Int -> Handler es BenchMessage
ioBoundHandler delayMicros counterRef _ingested = do
  liftIO $ threadDelay delayMicros
  _ <- liftIO $ atomicModifyIORef' counterRef (\c -> (c + 1, c + 1))
  pure AckOk

-- | Run with specific concurrency mode
runWithConcurrency :: Concurrency -> (forall es. (IOE :> es) => IORef Int -> Handler es BenchMessage) -> Int -> IO Int
runWithConcurrency concurrency mkHandler n = do
  counterRef <- newIORef 0
  runEff $ runTracingNoop $ do
    msgs <- createIngestedMessages n
    let handler = mkHandler counterRef
    let adapter =
          Adapter
            { adapterName = "test:list",
              source = Stream.fromList msgs,
              shutdown = pure ()
            }
    master <- startMaster IgnoreAll
    _ <- runSupervised master 100 (ProcessorId "test") concurrency adapter handler
    liftIO $ waitForCount counterRef n
    stopMaster master
    liftIO $ readIORef counterRef

-- | Wait for counter
waitForCount :: IORef Int -> Int -> IO ()
waitForCount counterRef expected = go (0 :: Int)
  where
    go attempts = do
      count <- readIORef counterRef
      if count >= expected
        then pure ()
        else
          if attempts > 10000 -- 1 second timeout
            then error $ "Timeout waiting for count: got " ++ show count ++ ", expected " ++ show expected
            else do
              threadDelay 100
              go (attempts + 1)

-- | CPU-bound handler
cpuBoundHandler :: (IOE :> es) => IORef Int -> Handler es BenchMessage
cpuBoundHandler counterRef ingested = do
  let result = ingested.envelope.payload.msgId * 2
  result `seq` pure ()
  _ <- liftIO $ atomicModifyIORef' counterRef (\c -> (c + 1, c + 1))
  pure AckOk

-- | Fixed time
benchTime :: UTCTime
benchTime = UTCTime (fromGregorian 2024 1 1) 0

-- | Create messages
createIngestedMessages :: (IOE :> es) => Int -> Eff es [Ingested es BenchMessage]
createIngestedMessages n = mapM createMessage [1 .. n]
  where
    createMessage i = do
      let msgId' = MessageId $ Text.pack $ show i
          envelope =
            Envelope
              { messageId = msgId',
                cursor = Nothing,
                partition = Nothing,
                enqueuedAt = Just benchTime,
                traceContext = Nothing,
                attempt = Nothing,
                payload = BenchMessage i (Text.pack $ "payload-" <> show i)
              }
          ackHandle = AckHandle $ \_ -> pure ()
      pure $
        Ingested
          { envelope = envelope,
            ack = ackHandle,
            lease = Nothing
          }
